import * as net from "node:net";
import { randomUUID } from "node:crypto";
import { ConnectionLost, ProtocolError } from "./errors.js";
import { serverError } from "./core.js";
import { encodeFrame, FrameDecoder, PROTOCOL_VERSION, type Envelope } from "./protocol.js";
import type { JSONObject } from "./types.js";

interface SocketConfig {
  readonly socketPath: string;
  readonly maxFrameBytes: number;
  readonly requestTimeout: number;
  readonly connectTimeout: number;
  readonly reconnectInitialDelay: number;
  readonly reconnectMaxDelay: number;
}

interface SocketCallbacks {
  bootstrap(connection: net.Socket): Promise<void>;
  onExecution(message: Envelope, connection: net.Socket): Promise<void>;
  onDisconnect(connection: net.Socket): void;
}

interface Pending {
  resolve(value: JSONObject): void;
  reject(error: unknown): void;
  timer: NodeJS.Timeout;
}

interface Session {
  socket: net.Socket;
  pending: Map<string, Pending>;
  eventRequests: Set<string>;
  expiredRequests: Set<string>;
  retired: boolean;
  error: Error;
}

const MAX_EXPIRED_REQUESTS = 1024;
const SOCKET_CLOSE_TIMEOUT_MS = 1000;

/** Internal socket lifecycle and request/reply transport. Never replays requests. */
export class SocketConnection {
  readonly #config: SocketConfig;
  readonly #callbacks: SocketCallbacks;
  #session: Session | undefined;
  #running = false;
  #connected = false;
  #supervisor: Promise<void> | undefined;
  #closing: Promise<void> | undefined;
  #wakeDelay: (() => void) | undefined;
  #connectWaiters: Array<{ resolve(): void; reject(error: unknown): void }> = [];

  constructor(config: SocketConfig, callbacks: SocketCallbacks) {
    this.#config = config;
    this.#callbacks = callbacks;
  }

  get connected(): boolean { return this.#connected; }
  get socket(): net.Socket | undefined { return this.#session?.socket; }

  async start(): Promise<void> {
    if (this.#closing) await this.#closing;
    if (!this.#running) {
      this.#running = true;
      this.#supervisor = this.supervise();
    }
    if (this.#connected) return;
    await new Promise<void>((resolve, reject) => this.#connectWaiters.push({ resolve, reject }));
  }

  async close(): Promise<void> {
    if (this.#closing) return this.#closing;
    const closing = this.stop();
    this.#closing = closing;
    try { await closing; }
    finally { this.#closing = undefined; }
  }

  private async stop(): Promise<void> {
    const wasConnected = this.#connected;
    this.#running = false;
    this.#connected = false;
    const error = new ConnectionLost("Tay client was closed");
    for (const waiter of this.#connectWaiters.splice(0)) waiter.reject(error);
    const session = this.#session;
    let closeTimer: NodeJS.Timeout | undefined;
    if (session) {
      session.error = error;
      this.retire(session);
      if (wasConnected) {
        // Send FIN and keep draining final acknowledgements. Destroying a Unix
        // socket with unread data can reset the peer on Linux.
        closeTimer = setTimeout(() => session.socket.destroy(), SOCKET_CLOSE_TIMEOUT_MS);
        session.socket.end();
      } else session.socket.destroy();
    }
    this.#wakeDelay?.();
    try { await this.#supervisor?.catch(() => undefined); }
    finally {
      clearTimeout(closeTimer);
      this.#supervisor = undefined;
    }
  }

  private async supervise(): Promise<void> {
    let delay = this.#config.reconnectInitialDelay;
    while (this.#running) {
      try {
        await this.connectOnce();
        delay = this.#config.reconnectInitialDelay;
      } catch (error) {
        if (!this.#running) return;
        for (const waiter of this.#connectWaiters.splice(0)) waiter.reject(error);
        await new Promise<void>((resolve) => {
          const timer = setTimeout(resolve, delay * 1000);
          this.#wakeDelay = () => { clearTimeout(timer); resolve(); };
        });
        this.#wakeDelay = undefined;
        delay = Math.min(this.#config.reconnectMaxDelay, delay * 2);
      }
    }
  }

  private async connectOnce(): Promise<void> {
    const socket = net.createConnection(this.#config.socketPath);
    const session: Session = {
      socket,
      pending: new Map(),
      eventRequests: new Set(),
      expiredRequests: new Set(),
      retired: false,
      error: new ConnectionLost("connection to Tay was lost"),
    };
    this.#session = session;
    // Retain an error listener after connect, including protocol failures and shutdown.
    socket.on("error", (error) => { session.error = error; });
    const closed = new Promise<void>((resolve) => socket.once("close", () => {
      this.retire(session);
      resolve();
    }));
    socket.setNoDelay(true);
    const connectTimer = setTimeout(() => socket.destroy(new ConnectionLost("Tay socket connection timed out")), this.#config.connectTimeout * 1000);
    try {
      try {
        await new Promise<void>((resolve, reject) => {
          const cleanup = () => {
            socket.off("connect", connected);
            socket.off("error", failed);
            socket.off("close", disconnected);
          };
          const connected = () => { cleanup(); resolve(); };
          const failed = (error: Error) => { cleanup(); reject(error); };
          const disconnected = () => { cleanup(); reject(session.error); };
          socket.once("connect", connected);
          socket.once("error", failed);
          socket.once("close", disconnected);
        });
      } finally { clearTimeout(connectTimer); }
      if (!this.#running || this.#session !== session || session.retired) return;
      const decoder = new FrameDecoder(this.#config.maxFrameBytes);
      // A queue belongs to one socket. Old queued frames cannot launch work
      // or act on a new connection's pending calls after their socket retires.
      let messageChain = Promise.resolve();
      socket.on("data", (chunk: Buffer) => {
        try {
          for (const message of decoder.push(chunk)) {
            messageChain = messageChain.then(async () => {
              if (this.#session === session && !session.retired && !socket.destroyed) await this.handleMessage(message, session);
            }).catch((error) => {
              socket.destroy(error instanceof Error ? error : new ProtocolError(String(error)));
            });
          }
        } catch (error) {
          socket.destroy(error instanceof Error ? error : new ProtocolError(String(error)));
        }
      });
      await this.#callbacks.bootstrap(socket);
      if (!this.#running || this.#session !== session || session.retired || socket.destroyed) return;
      this.#connected = true;
      for (const waiter of this.#connectWaiters.splice(0)) waiter.resolve();
      await closed;
    } finally {
      clearTimeout(connectTimer);
      socket.destroy();
      await closed;
    }
  }

  private retire(session: Session): void {
    if (session.retired) return;
    session.retired = true;
    if (this.#session === session) {
      this.#connected = false;
      this.#session = undefined;
    }
    for (const pending of session.pending.values()) {
      clearTimeout(pending.timer);
      pending.reject(new ConnectionLost(session.error.message));
    }
    session.pending.clear();
    session.eventRequests.clear();
    session.expiredRequests.clear();
    this.#callbacks.onDisconnect(session.socket);
  }

  exchange(type: string, fields: JSONObject, connection = this.socket): Promise<JSONObject> {
    const session = this.#session;
    if (!session || !connection || session.socket !== connection || session.retired || connection.destroyed) {
      return Promise.reject(new ConnectionLost("Tay socket is not connected"));
    }
    const requestId = randomUUID().replaceAll("-", "");
    return new Promise<JSONObject>((resolve, reject) => {
      const timer = setTimeout(() => {
        session.pending.delete(requestId);
        // A timeout ends the wait, not the server's command. Consume its late
        // reply without retiring unrelated executions; keep this set bounded.
        session.expiredRequests.add(requestId);
        if (session.expiredRequests.size > MAX_EXPIRED_REQUESTS) {
          session.expiredRequests.delete(session.expiredRequests.values().next().value!);
        }
        reject(new ConnectionLost(`Tay did not reply to ${type} within ${this.#config.requestTimeout}s`));
      }, this.#config.requestTimeout * 1000);
      session.pending.set(requestId, { resolve, reject, timer });
      this.write({ version: PROTOCOL_VERSION, type, request_id: requestId, ...fields }, connection).catch((error) => {
        const pending = session.pending.get(requestId);
        if (pending) { clearTimeout(pending.timer); session.pending.delete(requestId); pending.reject(error); }
      });
    });
  }

  async sendEvent(type: string, fields: JSONObject, connection = this.socket): Promise<void> {
    const session = this.#session;
    if (!session || !connection || session.socket !== connection || session.retired) throw new ConnectionLost("Tay socket is not connected");
    const requestId = randomUUID().replaceAll("-", "");
    session.eventRequests.add(requestId);
    try { await this.write({ version: PROTOCOL_VERSION, type, request_id: requestId, ...fields }, connection); }
    catch (error) { session.eventRequests.delete(requestId); throw error; }
  }

  private async write(envelope: Envelope, connection: net.Socket): Promise<void> {
    if (connection.destroyed || connection !== this.socket) throw new ConnectionLost("Tay socket disconnected before request could be sent");
    const frame = encodeFrame(envelope, this.#config.maxFrameBytes);
    await new Promise<void>((resolve, reject) => {
      connection.write(frame, (error) => { if (error) reject(error); else resolve(); });
    });
  }

  private async handleMessage(message: Envelope, session: Session): Promise<void> {
    if (message.type === "execute" || message.type === "cancel_execution") return this.#callbacks.onExecution(message, session.socket);
    if (message.type === "ping") {
      await this.sendEvent("pong", { ping_id: message.ping_id ?? null }, session.socket);
      return;
    }
    const requestId = message.request_id;
    if (session.expiredRequests.delete(requestId)) return;
    if ((message.type === "accepted" || message.type === "heartbeat_ok") && session.eventRequests.delete(requestId)) return;
    const pending = session.pending.get(requestId);
    if (!pending) throw new ProtocolError(`unexpected protocol message type ${message.type}`);
    session.pending.delete(requestId);
    clearTimeout(pending.timer);
    if (message.type === "error" || message.type === "protocol_error") pending.reject(serverError(message.error ?? message));
    else pending.resolve(message);
  }
}
