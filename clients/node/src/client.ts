import * as net from "node:net";
import { randomUUID } from "node:crypto";
import { once } from "node:events";
import { ConnectionLost, ModeError, ProtocolError, TaskRegistrationError, ValidationError } from "./errors.js";
import {
  errorPayload,
  executeTask,
  extractDurability,
  extractIdentifier,
  extractResult,
  JobHandle,
  Scheduling,
  serverError,
  Task,
} from "./core.js";
import { DEFAULT_MAX_FRAME_BYTES, encodeFrame, FrameDecoder, PROTOCOL_VERSION, type Envelope } from "./protocol.js";
import type { EnqueueOptions, JSONObject, JSONValue, TaskDefaults, TaskHandler } from "./types.js";
import { identifier, jsonObject, normalizeJSON, resolveSocketPath, validateEnqueueOptions, validateTaskName } from "./validation.js";

export type TayMode = "client" | "embedded" | "worker";

export interface TayOptions {
  mode?: TayMode;
  socketPath?: string;
  capacity?: number;
  clientId?: string;
  maxFrameBytes?: number;
  maxResultBytes?: number;
  maxErrorBytes?: number;
  requestTimeout?: number;
  connectTimeout?: number;
  reconnectInitialDelay?: number;
  reconnectMaxDelay?: number;
}

interface Pending {
  resolve(value: JSONObject): void;
  reject(error: unknown): void;
  timer: NodeJS.Timeout;
}

function positive(value: number, name: string): number {
  if (!Number.isFinite(value) || value <= 0) throw new ValidationError(`${name} must be positive and finite`);
  return value;
}

export class Tay extends Scheduling {
  readonly mode: TayMode;
  readonly socketPath: string;
  readonly capacity: number;
  readonly clientId: string;
  readonly maxFrameBytes: number;
  readonly maxResultBytes: number;
  readonly maxErrorBytes: number;
  readonly requestTimeout: number;
  readonly connectTimeout: number;
  readonly reconnectInitialDelay: number;
  readonly reconnectMaxDelay: number;
  readonly tasks = new Map<string, Task>();
  readonly #registered = new Set<string>();
  readonly #pending = new Map<string, Pending>();
  readonly #eventRequests = new Set<string>();
  readonly #executions = new Map<string, AbortController>();
  readonly #scheduleDeclarations = new Map<string, JSONObject>();
  #socket: net.Socket | undefined;
  #running = false;
  #connected = false;
  #supervisor: Promise<void> | undefined;
  #connectWaiters: Array<{ resolve(): void; reject(error: unknown): void }> = [];
  #messageChain = Promise.resolve();

  constructor(options: TayOptions = {}) {
    super();
    this.mode = options.mode ?? "embedded";
    if (!["client", "embedded", "worker"].includes(this.mode)) throw new ValidationError("mode must be client, embedded, or worker");
    this.socketPath = resolveSocketPath(options.socketPath);
    this.capacity = options.capacity ?? 1;
    if (!Number.isInteger(this.capacity) || this.capacity < 1 || this.capacity > 65_535) throw new ValidationError("capacity must be an integer in 1..65535");
    this.clientId = identifier(options.clientId ?? `node-${randomUUID().replaceAll("-", "")}`, "clientId");
    this.maxFrameBytes = options.maxFrameBytes ?? DEFAULT_MAX_FRAME_BYTES;
    this.maxResultBytes = options.maxResultBytes ?? 65_536;
    this.maxErrorBytes = options.maxErrorBytes ?? 8_192;
    if (!Number.isInteger(this.maxFrameBytes) || this.maxFrameBytes < 256) throw new ValidationError("maxFrameBytes must be at least 256");
    if (!Number.isInteger(this.maxResultBytes) || this.maxResultBytes < 1) throw new ValidationError("maxResultBytes must be positive");
    if (!Number.isInteger(this.maxErrorBytes) || this.maxErrorBytes < 128) throw new ValidationError("maxErrorBytes must be at least 128");
    this.requestTimeout = positive(options.requestTimeout ?? 30, "requestTimeout");
    this.connectTimeout = positive(options.connectTimeout ?? 5, "connectTimeout");
    this.reconnectInitialDelay = positive(options.reconnectInitialDelay ?? 0.05, "reconnectInitialDelay");
    this.reconnectMaxDelay = positive(options.reconnectMaxDelay ?? 2, "reconnectMaxDelay");
    if (this.reconnectMaxDelay < this.reconnectInitialDelay) throw new ValidationError("invalid reconnect delay configuration");
  }

  get connected(): boolean { return this.#connected; }

  task(name: string, handler: TaskHandler, defaults: TaskDefaults = {}): Task {
    if (this.mode === "client") throw new ModeError("client mode cannot register execution tasks");
    if (this.tasks.has(name)) throw new ValidationError(`task ${name} is already registered`);
    const task = new Task(this, name, handler, defaults);
    this.tasks.set(task.name, task);
    this.#registered.add(task.name);
    return task;
  }

  async start(): Promise<this> {
    if (!this.#running) {
      this.#running = true;
      this.#supervisor = this.supervise();
    }
    if (this.#connected) return this;
    await new Promise<void>((resolve, reject) => this.#connectWaiters.push({ resolve, reject }));
    return this;
  }

  async close(): Promise<void> {
    this.#running = false;
    this.#connected = false;
    for (const controller of this.#executions.values()) controller.abort(new Error("Tay client closed"));
    this.#executions.clear();
    const error = new ConnectionLost("Tay client was closed");
    this.rejectPending(error);
    for (const waiter of this.#connectWaiters.splice(0)) waiter.reject(error);
    this.#socket?.end();
    this.#socket = undefined;
    await this.#supervisor?.catch(() => undefined);
    this.#supervisor = undefined;
  }

  async enqueue(task: string | Task, args: JSONObject = {}, options: EnqueueOptions = {}): Promise<JobHandle> {
    if (this.mode === "worker") throw new ModeError("worker mode only executes tasks; use embedded or client to enqueue");
    const taskName = task instanceof Task ? task.name : validateTaskName(task);
    const reply = await this.request("enqueue", {
      task: taskName,
      args: jsonObject(args, "enqueue"),
      options: normalizeJSON(validateEnqueueOptions(options)) as JSONObject,
    });
    return new JobHandle(extractIdentifier(reply, "job_id", "job"), this, extractDurability(reply));
  }

  async status(jobId: string): Promise<unknown> {
    const reply = await this.request("status", { job_id: identifier(jobId, "jobId") });
    return reply.status ?? reply.job ?? reply;
  }

  async cancel(jobId: string): Promise<unknown> {
    const reply = await this.request("cancel", { job_id: identifier(jobId, "jobId") });
    return reply.status ?? reply;
  }

  async result(jobId: string): Promise<JSONValue> {
    return extractResult(await this.request("result", { job_id: identifier(jobId, "jobId") }));
  }

  override scheduleRequest(operation: string, payload: JSONObject): Promise<JSONObject> {
    if (this.mode === "worker") throw new ModeError("worker mode only executes tasks; use embedded or client to schedule");
    return this.request(operation, payload);
  }

  async registerTasks(...tasks: Array<string | Task>): Promise<Task[]> {
    if (this.mode === "client") throw new ModeError("client mode cannot register execution tasks");
    const names = [...new Set(tasks.map((task) => this.registeredName(task)))];
    names.forEach((name) => this.#registered.add(name));
    if (names.length) await this.request("register_tasks", { tasks: names });
    return names.map((name) => this.tasks.get(name)!);
  }

  async unregisterTasks(...tasks: Array<string | Task>): Promise<string[]> {
    if (this.mode === "client") throw new ModeError("client mode cannot unregister execution tasks");
    const names = [...new Set(tasks.map((task) => this.registeredName(task)))];
    names.forEach((name) => this.#registered.delete(name));
    if (names.length) await this.request("unregister_tasks", { tasks: names });
    return names;
  }

  protected override async declareSchedule(payload: JSONObject): Promise<import("./core.js").ScheduleHandle> {
    const handle = await super.declareSchedule(payload);
    this.#scheduleDeclarations.set(handle.id, { ...payload, declaration_id: handle.id });
    return handle;
  }

  override async cancelSchedule(scheduleId: string): Promise<unknown> {
    this.#scheduleDeclarations.delete(scheduleId);
    return super.cancelSchedule(scheduleId);
  }

  private registeredName(task: string | Task): string {
    const name = task instanceof Task ? task.name : validateTaskName(task);
    if (!this.tasks.has(name)) throw new TaskRegistrationError(`task ${name} is not registered on this Tay instance`);
    return name;
  }

  private async supervise(): Promise<void> {
    let delay = this.reconnectInitialDelay;
    while (this.#running) {
      try {
        await this.connectOnce();
        delay = this.reconnectInitialDelay;
      } catch (error) {
        if (!this.#running) return;
        if (this.#connectWaiters.length) {
          for (const waiter of this.#connectWaiters.splice(0)) waiter.reject(error);
        }
        await new Promise((resolve) => setTimeout(resolve, delay * 1000));
        delay = Math.min(this.reconnectMaxDelay, delay * 2);
      }
    }
  }

  private async connectOnce(): Promise<void> {
    const socket = net.createConnection(this.socketPath);
    const decoder = new FrameDecoder(this.maxFrameBytes);
    this.#socket = socket;
    socket.setNoDelay(true);
    const connectTimer = setTimeout(() => socket.destroy(new ConnectionLost("Tay socket connection timed out")), this.connectTimeout * 1000);
    try {
      await once(socket, "connect");
    } finally {
      clearTimeout(connectTimer);
    }
    if (!this.#running || this.#socket !== socket) { socket.destroy(); return; }
    socket.on("data", (chunk: Buffer) => {
      try {
        for (const message of decoder.push(chunk)) {
          this.#messageChain = this.#messageChain.then(() => this.handleMessage(message)).catch((error) => {
            socket.destroy(error instanceof Error ? error : new ProtocolError(String(error)));
          });
        }
      } catch (error) {
        socket.destroy(error instanceof Error ? error : new ProtocolError(String(error)));
      }
    });
    const closed = new Promise<void>((resolve) => socket.once("close", resolve));
    try {
      await this.exchange("hello", { mode: this.mode, runtime_id: this.clientId, max_concurrency: this.mode === "client" ? 0 : this.capacity }, socket);
      const declarations = new Map(this.#scheduleDeclarations);
      for (const task of this.tasks.values()) {
        const declaration = task.staticSchedule();
        if (declaration && typeof declaration.declaration_id === "string") declarations.set(declaration.declaration_id, declaration);
      }
      for (const [, declaration] of [...declarations].sort(([a], [b]) => a.localeCompare(b))) await this.exchange("schedule", declaration, socket);
      if (this.mode !== "client" && this.#registered.size) await this.exchange("register_tasks", { tasks: [...this.#registered].sort() }, socket);
      this.#connected = true;
      for (const waiter of this.#connectWaiters.splice(0)) waiter.resolve();
      await closed;
    } finally {
      if (this.#socket === socket) {
        this.#connected = false;
        this.#socket = undefined;
        this.#eventRequests.clear();
        this.rejectPending(new ConnectionLost("connection to Tay was lost"));
        for (const controller of this.#executions.values()) controller.abort(new ConnectionLost("execution connection was retired"));
        this.#executions.clear();
      }
      socket.destroy();
    }
  }

  private async request(type: string, fields: JSONObject): Promise<JSONObject> {
    await this.start();
    return this.exchange(type, fields);
  }

  private exchange(type: string, fields: JSONObject, connection = this.#socket): Promise<JSONObject> {
    if (!connection || connection.destroyed) return Promise.reject(new ConnectionLost("Tay socket is not connected"));
    const requestId = randomUUID().replaceAll("-", "");
    return new Promise<JSONObject>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.#pending.delete(requestId);
        reject(new ConnectionLost(`Tay did not reply to ${type} within ${this.requestTimeout}s`));
      }, this.requestTimeout * 1000);
      this.#pending.set(requestId, { resolve, reject, timer });
      this.write({ version: PROTOCOL_VERSION, type, request_id: requestId, ...fields }, connection).catch((error) => {
        const pending = this.#pending.get(requestId);
        if (pending) { clearTimeout(pending.timer); this.#pending.delete(requestId); pending.reject(error); }
      });
    });
  }

  private async sendEvent(type: string, fields: JSONObject, connection = this.#socket): Promise<void> {
    if (!connection) throw new ConnectionLost("Tay socket is not connected");
    const requestId = randomUUID().replaceAll("-", "");
    this.#eventRequests.add(requestId);
    try { await this.write({ version: PROTOCOL_VERSION, type, request_id: requestId, ...fields }, connection); }
    catch (error) { this.#eventRequests.delete(requestId); throw error; }
  }

  private async write(envelope: Envelope, connection: net.Socket): Promise<void> {
    if (connection.destroyed || connection !== this.#socket) throw new ConnectionLost("Tay socket disconnected before request could be sent");
    if (!connection.write(encodeFrame(envelope, this.maxFrameBytes))) await once(connection, "drain");
  }

  private async handleMessage(message: Envelope): Promise<void> {
    if (message.type === "execute") return this.acceptExecution(message);
    if (message.type === "cancel_execution") {
      if (typeof message.execution_id !== "string") throw new ProtocolError("cancel_execution requires execution_id");
      this.#executions.get(message.execution_id)?.abort(new Error("execution cancelled"));
      return;
    }
    if (message.type === "ping") {
      await this.sendEvent("pong", { ping_id: message.ping_id ?? null });
      return;
    }
    const requestId = message.request_id;
    if ((message.type === "accepted" || message.type === "heartbeat_ok") && this.#eventRequests.delete(requestId)) return;
    const pending = this.#pending.get(requestId);
    if (!pending) throw new ProtocolError(`unexpected protocol message type ${message.type}`);
    this.#pending.delete(requestId);
    clearTimeout(pending.timer);
    if (message.type === "error" || message.type === "protocol_error") pending.reject(serverError(message.error ?? message));
    else pending.resolve(message);
  }

  private async acceptExecution(message: Envelope): Promise<void> {
    const executionId = message.execution_id;
    const reservationId = message.reservation_id;
    const jobId = message.job_id;
    const taskName = message.task ?? message.task_name;
    if (typeof executionId !== "string" || typeof reservationId !== "string" || typeof jobId !== "string" || typeof taskName !== "string") {
      throw new ProtocolError("execute requires execution_id, reservation_id, job_id, and task");
    }
    if (this.#executions.has(executionId)) {
      await this.sendEvent("started", { reservation_id: reservationId, execution_id: executionId });
      return;
    }
    if (this.#executions.size >= this.capacity) {
      await this.sendEvent("failed", { reservation_id: reservationId, execution_id: executionId, job_id: jobId, error: { type: "ServerError", code: "over_capacity" } });
      return;
    }
    const task = this.tasks.get(taskName);
    if (!task) {
      await this.sendEvent("failed", { reservation_id: reservationId, execution_id: executionId, job_id: jobId, error: { type: "TaskNotRegistered" } });
      return;
    }
    const controller = new AbortController();
    this.#executions.set(executionId, controller);
    const connection = this.#socket;
    void this.runExecution(task, message.args, { reservation_id: reservationId, execution_id: executionId, job_id: jobId }, controller, connection)
      .finally(() => this.#executions.delete(executionId));
  }

  private async runExecution(task: Task, args: unknown, context: JSONObject, controller: AbortController, connection?: net.Socket): Promise<void> {
    if (!connection || connection !== this.#socket) return;
    await this.sendEvent("started", context, connection);
    try {
      const result = await executeTask(task, args, controller.signal, this.maxResultBytes);
      if (connection === this.#socket) await this.sendEvent("succeeded", { ...context, result }, connection);
    } catch (error) {
      if (connection === this.#socket) await this.sendEvent("failed", { ...context, error: errorPayload(error, this.maxErrorBytes) }, connection).catch(() => undefined);
    }
  }

  private rejectPending(error: unknown): void {
    for (const pending of this.#pending.values()) { clearTimeout(pending.timer); pending.reject(error); }
    this.#pending.clear();
  }
}
