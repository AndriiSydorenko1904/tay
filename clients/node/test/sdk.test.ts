import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import http from "node:http";
import net from "node:net";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { afterEach, test } from "node:test";
import {
  FrameDecoder,
  JobHandle,
  ProtocolError,
  ServerError,
  Tay,
  TayHTTP,
  TayHTTPWorker,
  ValidationError,
  decodePayload,
  encodeFrame,
  resolveSocketPath,
} from "../src/index.js";
import type { Envelope } from "../src/protocol.js";
import type { JSONObject } from "../src/types.js";

const cleanup: Array<() => Promise<void>> = [];
afterEach(async () => {
  while (cleanup.length) await cleanup.pop()!();
});

test("Protocol v1 frames are bounded and support fragmented input", () => {
  const envelope = { version: 1, type: "enqueue", request_id: "abc", task: "echo", args: {} };
  const frame = encodeFrame(envelope);
  assert.deepEqual(decodePayload(frame.subarray(4)), envelope);
  const decoder = new FrameDecoder();
  assert.deepEqual(decoder.push(frame.subarray(0, 3)), []);
  assert.deepEqual(decoder.push(frame.subarray(3)), [envelope]);
  assert.throws(() => decodePayload(Buffer.from("{")), ProtocolError);
  assert.throws(() => encodeFrame({ ...envelope, args: { value: Number.NaN } }), ValidationError);
});

test("socket discovery follows explicit and environment precedence", () => {
  assert.equal(resolveSocketPath("/tmp/tay-test.sock"), "/tmp/tay-test.sock");
  assert.equal(resolveSocketPath(undefined, { TAY_SOCKET_PATH: "/tmp/from-env.sock" }, 42), "/tmp/from-env.sock");
  assert.throws(() => resolveSocketPath("relative.sock"), ValidationError);
});

test("job waiting retries only result_not_ready and preserves JSON null", async () => {
  let attempts = 0;
  const handle = new JobHandle("job-wait", {
    status: async () => "completed",
    cancel: async () => "cancelled",
    result: async () => {
      attempts += 1;
      if (attempts < 3) throw new ServerError("not ready", { code: "result_not_ready" });
      return null;
    },
  });
  assert.equal(await handle.waitResult({ timeout: 1, pollInterval: 0.001 }), null);
  assert.equal(attempts, 3);
});

test("transport and enqueue validation fail before network I/O", async () => {
  assert.throws(() => new TayHTTP("http://example.com:8080"), ValidationError);
  const tay = new TayHTTP("http://127.0.0.1:1", { requestTimeout: 0.01 });
  await assert.rejects(tay.enqueue("example.task", {}, { retries: 65_535 }), ValidationError);
  await assert.rejects(tay.enqueue("example.task", {}, { delay: 1, delay_ms: 1 }), ValidationError);
  await assert.rejects(tay.enqueue("example.task", {}, { id: "0".repeat(32) }), ValidationError);
});

test("HTTP producer maps jobs, results, cancellation, and schedules", async () => {
  const requests: Array<{ method: string | undefined; url: string | undefined; body?: JSONObject }> = [];
  const server = http.createServer(async (request, response) => {
    const chunks: Buffer[] = [];
    for await (const chunk of request) chunks.push(chunk as Buffer);
    const raw = Buffer.concat(chunks);
    requests.push({ method: request.method, url: request.url, ...(raw.length ? { body: JSON.parse(raw.toString()) as JSONObject } : {}) });
    response.setHeader("content-type", "application/json");
    if (request.method === "POST" && request.url === "/jobs") { response.statusCode = 201; response.end(JSON.stringify({ job: { id: "job-1", durability: "persistent" } })); return; }
    if (request.url === "/jobs/job-1/result") { response.end(JSON.stringify({ result: { ok: true } })); return; }
    if (request.method === "GET" && request.url === "/jobs/job-1") { response.end(JSON.stringify({ status: "completed" })); return; }
    if (request.method === "DELETE" && request.url === "/jobs/job-1") { response.end(JSON.stringify({ status: "cancelled" })); return; }
    if (request.method === "POST" && request.url === "/schedules") { response.statusCode = 201; response.end(JSON.stringify({ schedule_id: "schedule-1" })); return; }
    if (request.method === "GET" && request.url === "/schedules/schedule-1") { response.end(JSON.stringify({ schedule: { id: "schedule-1", state: "active" } })); return; }
    if (request.method === "DELETE" && request.url === "/schedules/schedule-1") { response.end(JSON.stringify({ status: "cancelled" })); return; }
    if (request.method === "GET" && request.url === "/schedules") { response.end(JSON.stringify({ schedules: [{ id: "schedule-1" }] })); return; }
    response.statusCode = 404; response.end(JSON.stringify({ error: { code: "missing", message: "not found" } }));
  });
  server.listen(0, "127.0.0.1");
  await new Promise<void>((resolve) => server.once("listening", resolve));
  cleanup.push(() => new Promise<void>((resolve) => server.close(() => resolve())));
  const address = server.address();
  assert(address && typeof address === "object");
  const tay = new TayHTTP(`http://127.0.0.1:${address.port}`);
  const job = await tay.enqueue("example.echo.v1", { value: "hello" }, { submission_id: "example:1" });
  assert(job instanceof JobHandle);
  assert.equal(job.id, "job-1");
  assert.equal(job.durability, "persistent");
  assert.equal(await job.status(), "completed");
  assert.deepEqual(await job.result(), { ok: true });
  assert.equal(await job.cancel(), "cancelled");
  const schedule = await tay.schedule("example.echo.v1", { cron: "0 8 * * 1-5", timezone: "+02", args: { value: "scheduled" } });
  assert.equal(schedule.id, "schedule-1");
  assert.equal((await schedule.status()).state, "active");
  assert.deepEqual(await tay.schedules(), [{ id: "schedule-1" }]);
  assert.equal(await schedule.cancel(), "cancelled");
  assert.deepEqual(requests[0]?.body, { task: "example.echo.v1", args: { value: "hello" }, options: { submission_id: "example:1" } });
});

test("local client handshakes, submits, and executes a registered task", async () => {
  const directory = await mkdtemp(join(tmpdir(), "tay-node-test-"));
  const socketPath = join(directory, "tay.sock");
  cleanup.push(async () => { await rm(directory, { recursive: true, force: true }); });
  const received: Envelope[] = [];
  let sendExecute: (() => void) | undefined;
  let resolveCompleted!: (message: Envelope) => void;
  const completed = new Promise<Envelope>((resolve) => { resolveCompleted = resolve; });
  const server = net.createServer((socket) => {
    const decoder = new FrameDecoder();
    socket.on("data", (chunk) => {
      for (const message of decoder.push(chunk)) {
        received.push(message);
        const reply = (type: string, fields: JSONObject = {}) => socket.write(encodeFrame({ version: 1, type, request_id: message.request_id, ...fields }));
        if (message.type === "hello") reply("hello_ok");
        else if (message.type === "register_tasks") {
          reply("accepted");
          sendExecute = () => socket.write(encodeFrame({
            version: 1,
            type: "execute",
            request_id: "server-execute-1",
            execution_id: "execution-1",
            reservation_id: "reservation-1",
            job_id: "job-execute-1",
            task: "example.double.v1",
            args: { value: 21 },
          }));
        } else if (message.type === "enqueue") reply("enqueued", { job_id: "job-submit-1", job: { durability: "volatile" } });
        else if (message.type === "started") reply("accepted");
        else if (message.type === "succeeded") { reply("accepted"); resolveCompleted(message); }
        else reply("accepted");
      }
    });
  });
  server.listen(socketPath);
  await new Promise<void>((resolve) => server.once("listening", resolve));
  cleanup.push(() => new Promise<void>((done) => server.close(() => done())));
  const tay = new Tay({ socketPath, capacity: 2 });
  const task = tay.task("example.double.v1", ({ value }) => Number(value) * 2);
  await tay.start();
  const job = await task.enqueue({ value: 5 }, { durability: "volatile" });
  assert.equal(job.id, "job-submit-1");
  assert.equal(job.durability, "volatile");
  assert(sendExecute);
  sendExecute();
  const success = await completed;
  assert.equal(success.result, 42);
  assert.deepEqual(received.find((message) => message.type === "hello")?.mode, "embedded");
  await tay.close();
});

test("HTTP worker registers its typed task", async () => {
  let registration: JSONObject | undefined;
  let authorization: string | undefined;
  const token = "x".repeat(43);
  const server = http.createServer(async (request, response) => {
    const chunks: Buffer[] = [];
    for await (const chunk of request) chunks.push(chunk as Buffer);
    const raw = Buffer.concat(chunks);
    authorization = request.headers.authorization;
    response.setHeader("content-type", "application/json");
    if (request.method === "POST" && request.url === "/workers") {
      registration = JSON.parse(raw.toString()) as JSONObject;
      response.statusCode = 201;
      response.end(JSON.stringify({ worker_token: token }));
      return;
    }
    response.end("{}");
  });
  server.listen(0, "127.0.0.1");
  await new Promise<void>((resolve) => server.once("listening", resolve));
  cleanup.push(() => new Promise<void>((resolve) => server.close(() => resolve())));
  const address = server.address();
  assert(address && typeof address === "object");
  const worker = new TayHTTPWorker(`http://127.0.0.1:${address.port}`, { requestTimeout: 25, capacity: 4, runtimeId: "node-worker-test" });
  worker.task("example.echo.v1", ({ value }) => ({ value: value ?? null }));
  await worker.register();
  assert.deepEqual(registration, { runtime_id: "node-worker-test", tasks: ["example.echo.v1"], capacity: 4, queue: "default" });
  await worker.close();
  assert.equal(authorization, `Bearer ${token}`);
});

test("HTTP worker claims and completes an execution", async () => {
  const token = "w".repeat(43);
  let claimed = false;
  let completion: JSONObject | undefined;
  let resolveCompletion!: () => void;
  const completionReceived = new Promise<void>((resolve) => { resolveCompletion = resolve; });
  const server = http.createServer(async (request, response) => {
    const chunks: Buffer[] = [];
    for await (const chunk of request) chunks.push(chunk as Buffer);
    const raw = Buffer.concat(chunks);
    response.setHeader("content-type", "application/json");
    if (request.url === "/workers" && request.method === "POST") {
      response.statusCode = 201;
      response.end(JSON.stringify({ worker_token: token }));
      return;
    }
    assert.equal(request.headers.authorization, `Bearer ${token}`);
    if (request.url === "/queues/default/claim") {
      if (!claimed) {
        claimed = true;
        response.end(JSON.stringify({
          type: "execute",
          execution_id: "execution-http-1",
          reservation_id: "reservation-http-1",
          task: "example.add.v1",
          args: { left: 20, right: 22 },
        }));
      } else {
        response.end("{}");
      }
      return;
    }
    if (request.url === "/workers/started") { response.end("{}"); return; }
    if (request.url === "/workers/complete") {
      completion = JSON.parse(raw.toString()) as JSONObject;
      response.end("{}");
      resolveCompletion();
      return;
    }
    response.end("{}");
  });
  server.listen(0, "127.0.0.1");
  await new Promise<void>((resolve) => server.once("listening", resolve));
  cleanup.push(() => new Promise<void>((resolve) => server.close(() => resolve())));
  const address = server.address();
  assert(address && typeof address === "object");
  const worker = new TayHTTPWorker(`http://127.0.0.1:${address.port}`, { requestTimeout: 25 });
  worker.task("example.add.v1", ({ left, right }) => Number(left) + Number(right));
  const serving = worker.serve();
  await completionReceived;
  await worker.close();
  await serving;
  assert.deepEqual(completion, {
    reservation_id: "reservation-http-1",
    execution_id: "execution-http-1",
    outcome: "success",
    result: 42,
  });
});
