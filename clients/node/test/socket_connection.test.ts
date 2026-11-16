import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import net from "node:net";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { afterEach, test } from "node:test";
import { setImmediate as tick } from "node:timers/promises";
import { ConnectionLost, Tay } from "../src/index.js";
import { FrameDecoder, encodeFrame, type Envelope } from "../src/protocol.js";
import { SocketConnection } from "../src/socket_connection.js";
import type { JSONObject } from "../src/types.js";

function deferred<T = void>() {
  let resolve!: (value: T | PromiseLike<T>) => void;
  let reject!: (error: unknown) => void;
  const promise = new Promise<T>((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

const cleanup: Array<() => Promise<void>> = [];
afterEach(async () => {
  while (cleanup.length) await cleanup.pop()!();
});

interface PeerSession { socket: net.Socket; messages: Envelope[] }

async function listen(onMessage: (message: Envelope, session: PeerSession, index: number) => void | Promise<void>, options: net.ServerOpts = {}) {
  const directory = await mkdtemp(join(tmpdir(), "tay-transport-"));
  const socketPath = join(directory, "tay.sock");
  const sessions: PeerSession[] = [];
  const errors: unknown[] = [];
  const server = net.createServer(options, (socket) => {
    const session = { socket, messages: [] as Envelope[] };
    const index = sessions.push(session) - 1;
    const decoder = new FrameDecoder();
    let chain = Promise.resolve();
    socket.on("error", () => undefined);
    socket.on("data", (chunk: Buffer) => {
      for (const message of decoder.push(chunk)) {
        session.messages.push(message);
        chain = chain.then(() => onMessage(message, session, index)).catch((error) => {
          errors.push(error);
          socket.destroy();
        });
      }
    });
  });
  server.listen(socketPath);
  await new Promise<void>((resolve, reject) => { server.once("listening", resolve); server.once("error", reject); });
  cleanup.push(async () => {
    sessions.forEach(({ socket }) => socket.destroy());
    await new Promise<void>((resolve) => server.close(() => resolve()));
    await rm(directory, { recursive: true, force: true });
    assert.deepEqual(errors, []);
  });
  return { socketPath, sessions };
}

function reply(socket: net.Socket, message: Pick<Envelope, "request_id">, type: string, fields: JSONObject = {}) {
  socket.write(encodeFrame({ version: 1, type, request_id: message.request_id, ...fields }));
}

function dispatch(socket: net.Socket, id = "old-execution") {
  reply(socket, { request_id: `dispatch-${id}` }, "execute", {
    execution_id: id, reservation_id: `reservation-${id}`, job_id: `job-${id}`, task: "tests.running", args: {},
  });
}

function transport(socketPath: string, options = {}, onExecution: (message: Envelope, connection: net.Socket) => Promise<void> = async () => undefined) {
  let connection: SocketConnection;
  connection = new SocketConnection({
    socketPath, maxFrameBytes: 1_048_576, requestTimeout: 1, connectTimeout: 1,
    reconnectInitialDelay: 0.01, reconnectMaxDelay: 0.05, ...options,
  }, {
    bootstrap: async (socket) => { await connection.exchange("hello", {}, socket); },
    onExecution,
    onDisconnect: () => undefined,
  });
  cleanup.push(() => connection.close());
  return connection;
}

for (const lateError of [false, true]) {
  test(`late ${lateError ? "error" : "success"} reply preserves the socket and unrelated execution`, { timeout: 5000 }, async () => {
    const releaseReply = deferred();
    const entered = deferred<AbortSignal>();
    const cancelled = deferred();
    const settled = deferred();
    let firstStatus = true;
    const peer = await listen(async (message, { socket }) => {
      if (message.type === "status") {
        if (firstStatus) {
          firstStatus = false;
          await releaseReply.promise;
          reply(socket, message, lateError ? "error" : "status", lateError ? { error: { code: "not_found" } } : { status: "available" });
        } else reply(socket, message, "status", { status: "available" });
      } else {
        reply(socket, message, message.type === "hello" ? "hello_ok" : "accepted");
        if (message.type === "register_tasks") dispatch(socket);
        if (message.type === "failed") settled.resolve();
      }
    });
    const tay = new Tay({ socketPath: peer.socketPath, requestTimeout: 0.05 });
    tay.task("tests.running", async (_args, signal) => {
      entered.resolve(signal);
      return new Promise((resolve, reject) => {
        signal.addEventListener("abort", () => { cancelled.resolve(); reject(signal.reason); }, { once: true });
      });
    });
    cleanup.push(() => tay.close());
    try {
      await tay.start();
      const signal = await entered.promise;
      await assert.rejects(tay.status("slow-job"), ConnectionLost);
      releaseReply.resolve();
      assert.equal(await tay.status("next-job"), "available");
      assert.equal(tay.connected, true);
      assert.equal(peer.sessions.length, 1);
      assert.equal(signal.aborted, false);
      // Explicit cancellation still reaches the handler and settles on this socket.
      reply(peer.sessions[0]!.socket, { request_id: "cancel" }, "cancel_execution", { execution_id: "old-execution" });
      await cancelled.promise;
      await settled.promise;
      assert.equal(tay.connected, true);
    } finally { releaseReply.resolve(); }
  });
}

test("transport correlates reversed replies and keeps server errors local to the caller", { timeout: 5000 }, async () => {
  let first: Envelope | undefined;
  const peer = await listen((message, { socket }) => {
    if (message.type === "status") {
      if (!first) first = message;
      else {
        reply(socket, message, "status", { value: message.value! });
        reply(socket, first, "status", { value: first.value! });
      }
    } else if (message.type === "enqueue") reply(socket, message, "error", { error: { code: "capacity", message: "full" } });
    else reply(socket, message, "hello_ok");
  });
  const connection = transport(peer.socketPath);
  await connection.start();
  const socket = connection.socket;
  const results = await Promise.all([connection.exchange("status", { value: 1 }), connection.exchange("status", { value: 2 })]);
  assert.deepEqual(results.map((result) => result.value), [1, 2]);
  await assert.rejects(connection.exchange("enqueue", {}), { code: "capacity" });
  assert.equal(connection.socket, socket);
  assert.equal(connection.connected, true);
});

test("queued frames from a retired socket cannot block or execute on the new connection", { timeout: 5000 }, async () => {
  const held = deferred();
  const release = deferred();
  const reconnected = deferred();
  const fresh = deferred();
  const received: string[] = [];
  const peer = await listen((message, { socket }, index) => {
    reply(socket, message, "hello_ok");
    if (index === 1) reconnected.resolve();
  });
  const connection = transport(peer.socketPath, {}, async (message) => {
    received.push(message.request_id);
    if (message.request_id === "held") { held.resolve(); await release.promise; }
    if (message.request_id === "fresh") fresh.resolve();
  });
  try {
    await connection.start();
    const old = peer.sessions[0]!.socket;
    old.write(Buffer.concat(["held", "stale"].map((request_id) => encodeFrame({ version: 1, type: "execute", request_id }))));
    await held.promise;
    old.destroy();
    await reconnected.promise;
    await connection.start();
    reply(peer.sessions[1]!.socket, { request_id: "fresh" }, "execute");
    await fresh.promise;
    release.resolve();
    await tick();
    assert.deepEqual(received, ["held", "fresh"]);
  } finally { release.resolve(); }
});

test("expired request tracking is bounded and unknown replies still retire the connection", { timeout: 5000 }, async () => {
  const requests: Envelope[] = [];
  const reconnected = deferred();
  const peer = await listen((message, { socket }, index) => {
    if (message.type === "hello") {
      reply(socket, message, "hello_ok");
      if (index === 1) reconnected.resolve();
    } else if (message.marker === "barrier") reply(socket, message, "status", { status: "available" });
    else requests.push(message);
  });
  const connection = transport(peer.socketPath, { requestTimeout: 0.1 });
  await connection.start();
  const oldSocket = connection.socket;
  const outcomes = await Promise.allSettled(Array.from({ length: 1025 }, () => connection.exchange("status", {})));
  assert.equal(requests.length, 1025);
  assert(outcomes.every((outcome) => outcome.status === "rejected" && outcome.reason instanceof ConnectionLost));
  // The newest timeout is retained and its reply is harmless.
  reply(peer.sessions[0]!.socket, requests.at(-1)!, "status");
  await connection.exchange("status", { marker: "barrier" });
  assert.equal(connection.socket, oldSocket);
  // The oldest timeout was evicted. Unknown replies remain protocol violations.
  reply(peer.sessions[0]!.socket, requests[0]!, "status");
  await reconnected.promise;
  await connection.start();
  assert.notEqual(connection.socket, oldSocket);
  assert.equal(peer.sessions.length, 2);
});

for (const ignoresAbort of [false, true]) {
  test(`reconnect reconciles declarations without replay and ${ignoresAbort ? "retains capacity for work ignoring abort" : "cooperatively cancels work"}`, { timeout: 5000 }, async () => {
    const entered = deferred<AbortSignal>();
    const release = deferred<number>();
    const reconnected = deferred();
    const refused = deferred();
    const completed = deferred();
    let calls = 0;
    const peer = await listen((message, { socket }, index) => {
      if (message.type === "enqueue") { socket.destroy(); return; }
      reply(socket, message, message.type === "hello" ? "hello_ok" : message.type === "status" ? "status" : "accepted", { status: "available" });
      if (message.type === "register_tasks") {
        if (index === 0) dispatch(socket);
        else reconnected.resolve();
      }
      if (message.type === "failed" && message.execution_id === "refused") {
        assert.equal((message.error as JSONObject).code, "over_capacity");
        refused.resolve();
      }
      if (message.type === "succeeded" && message.execution_id === "new-execution") completed.resolve();
    });
    const tay = new Tay({ socketPath: peer.socketPath, capacity: 1, requestTimeout: 1 });
    tay.task("tests.running", async (_args, signal) => {
      calls++;
      if (calls > 1) return 42;
      entered.resolve(signal);
      if (ignoresAbort) return release.promise;
      return new Promise((resolve, reject) => {
        signal.addEventListener("abort", () => reject(signal.reason), { once: true });
      });
    }, { every: { seconds: 60 }, declarationId: "static-schedule" });
    cleanup.push(() => tay.close());
    try {
      assert.equal(await tay.start(), tay);
      const signal = await entered.promise;
      await assert.rejects(tay.enqueue("tests.running", { submission: "once" }), ConnectionLost);
      await reconnected.promise;
      await tay.start();
      assert.equal(signal.aborted, true);
      assert.equal(peer.sessions.length, 2);
      const current = peer.sessions[1]!;
      if (ignoresAbort) {
        dispatch(current.socket, "refused");
        await refused.promise;
        assert.equal(calls, 1);
      }
      release.resolve(7);
      await tick();
      assert.equal(await tay.status("barrier"), "available");
      dispatch(current.socket, "new-execution");
      await completed.promise;
      assert.equal(calls, 2);
      for (const session of peer.sessions) assert.deepEqual(session.messages.slice(0, 3).map((m) => m.type), ["hello", "schedule", "register_tasks"]);
      assert.equal(peer.sessions.flatMap((s) => s.messages).filter((m) => m.type === "enqueue").length, 1);
      assert(!current.messages.some((m) => m.execution_id === "old-execution"));
    } finally { release.resolve(7); }
  });
}

test("close interrupts handshake, releases pending callers, and permits restart", { timeout: 3000 }, async () => {
  const hello = deferred();
  const pending = deferred();
  let allowHandshake = false;
  const peer = await listen((message, { socket }) => {
    if (message.type === "hello") {
      hello.resolve();
      if (allowHandshake) reply(socket, message, "hello_ok");
    } else pending.resolve();
  });
  const connection = transport(peer.socketPath, { requestTimeout: 30 });
  const starting = assert.rejects(connection.start(), ConnectionLost);
  await hello.promise;
  await Promise.all([connection.close(), connection.close()]);
  await starting;
  assert.equal(connection.connected, false);
  allowHandshake = true;
  await connection.start();
  const waiting = assert.rejects(connection.exchange("status", {}), ConnectionLost);
  await pending.promise;
  await connection.close();
  await waiting;
  assert.equal(connection.connected, false);
});

test("close drains final acknowledgements and ends the peer without resetting it", { timeout: 3000 }, async () => {
  const acknowledged = deferred();
  const ended = deferred();
  const errors: Error[] = [];
  const peer = await listen((message, { socket }) => {
    if (message.type === "hello") {
      socket.on("error", (error) => errors.push(error));
      socket.once("end", () => ended.resolve());
      reply(socket, message, "hello_ok");
    } else {
      reply(socket, message, "accepted");
      acknowledged.resolve();
    }
  });
  const connection = transport(peer.socketPath);
  await connection.start();
  const sent = connection.sendEvent("succeeded", { execution_id: "finished" });
  // Close immediately after the peer writes its acknowledgement, before the
  // client's next read event can consume it.
  await acknowledged.promise;
  await sent;
  await connection.close();
  await ended.promise;
  assert.deepEqual(errors, []);
  assert.equal(connection.connected, false);
});

test("close is bounded when a half-open peer never ends its writable stream", { timeout: 3000 }, async () => {
  const ended = deferred();
  const peer = await listen((message, { socket }) => {
    socket.once("end", () => ended.resolve());
    reply(socket, message, "hello_ok");
  }, { allowHalfOpen: true });
  const connection = transport(peer.socketPath);
  await connection.start();
  const socket = connection.socket!;
  const closing = connection.close();
  await ended.promise;
  assert.equal(socket.destroyed, false);
  await closing;
  assert.equal(socket.destroyed, true);
  assert.equal(connection.connected, false);
});

test("close interrupts reconnect backoff after a failed connection", { timeout: 1000 }, async () => {
  const directory = await mkdtemp(join(tmpdir(), "tay-missing-"));
  cleanup.push(() => rm(directory, { recursive: true, force: true }));
  const connection = transport(join(directory, "missing.sock"), { reconnectInitialDelay: 60, reconnectMaxDelay: 60 });
  await assert.rejects(connection.start(), { code: "ENOENT" });
  await connection.close();
});
