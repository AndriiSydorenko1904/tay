import type * as net from "node:net";
import { randomUUID } from "node:crypto";
import { ConnectionLost, ModeError, ProtocolError, TaskRegistrationError, ValidationError } from "./errors.js";
import {
  errorPayload,
  executeTask,
  extractDurability,
  extractIdentifier,
  extractResult,
  JobHandle,
  Scheduling,
  Task,
} from "./core.js";
import { DEFAULT_MAX_FRAME_BYTES, type Envelope } from "./protocol.js";
import { SocketConnection } from "./socket_connection.js";
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

interface Execution {
  controller: AbortController;
  connection: net.Socket;
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
  readonly #connection: SocketConnection;
  readonly #executions = new Map<string, Execution>();
  readonly #scheduleDeclarations = new Map<string, JSONObject>();

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
    this.#connection = new SocketConnection(this, {
      bootstrap: (connection) => this.bootstrap(connection),
      onExecution: (message, connection) => this.handleExecutionMessage(message, connection),
      onDisconnect: (connection) => this.connectionDetached(connection),
    });
  }

  get connected(): boolean { return this.#connection.connected; }

  task(name: string, handler: TaskHandler, defaults: TaskDefaults = {}): Task {
    if (this.mode === "client") throw new ModeError("client mode cannot register execution tasks");
    if (this.tasks.has(name)) throw new ValidationError(`task ${name} is already registered`);
    const task = new Task(this, name, handler, defaults);
    this.tasks.set(task.name, task);
    this.#registered.add(task.name);
    return task;
  }

  async start(): Promise<this> {
    await this.#connection.start();
    return this;
  }

  async close(): Promise<void> {
    for (const { controller } of this.#executions.values()) controller.abort(new Error("Tay client closed"));
    this.#executions.clear();
    await this.#connection.close();
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

  private async bootstrap(connection: net.Socket): Promise<void> {
    await this.#connection.exchange("hello", { mode: this.mode, runtime_id: this.clientId, max_concurrency: this.mode === "client" ? 0 : this.capacity }, connection);
    const declarations = new Map(this.#scheduleDeclarations);
    for (const task of this.tasks.values()) {
      const declaration = task.staticSchedule();
      if (declaration && typeof declaration.declaration_id === "string") declarations.set(declaration.declaration_id, declaration);
    }
    for (const [, declaration] of [...declarations].sort(([a], [b]) => a.localeCompare(b))) await this.#connection.exchange("schedule", declaration, connection);
    if (this.mode !== "client" && this.#registered.size) await this.#connection.exchange("register_tasks", { tasks: [...this.#registered].sort() }, connection);
  }

  private connectionDetached(connection: net.Socket): void {
    for (const execution of this.#executions.values()) {
      if (execution.connection === connection) execution.controller.abort(new ConnectionLost("execution connection was retired"));
    }
    // AbortSignal is cooperative: retain capacity until the handler settles,
    // even if it ignores cancellation after its original socket retires.
  }

  private async request(type: string, fields: JSONObject): Promise<JSONObject> {
    await this.start();
    return this.#connection.exchange(type, fields);
  }

  private async handleExecutionMessage(message: Envelope, connection: net.Socket): Promise<void> {
    if (message.type === "execute") return this.acceptExecution(message, connection);
    if (typeof message.execution_id !== "string") throw new ProtocolError("cancel_execution requires execution_id");
    const execution = this.#executions.get(message.execution_id);
    if (execution?.connection === connection) execution.controller.abort(new Error("execution cancelled"));
  }

  private async acceptExecution(message: Envelope, connection: net.Socket): Promise<void> {
    const executionId = message.execution_id;
    const reservationId = message.reservation_id;
    const jobId = message.job_id;
    const taskName = message.task ?? message.task_name;
    if (typeof executionId !== "string" || typeof reservationId !== "string" || typeof jobId !== "string" || typeof taskName !== "string") {
      throw new ProtocolError("execute requires execution_id, reservation_id, job_id, and task");
    }
    const existing = this.#executions.get(executionId);
    if (existing?.connection === connection) {
      await this.#connection.sendEvent("started", { reservation_id: reservationId, execution_id: executionId }, connection);
      return;
    }
    if (existing || this.#executions.size >= this.capacity) {
      await this.#connection.sendEvent("failed", { reservation_id: reservationId, execution_id: executionId, job_id: jobId, error: { type: "ServerError", code: "over_capacity" } }, connection);
      return;
    }
    const task = this.tasks.get(taskName);
    if (!task) {
      await this.#connection.sendEvent("failed", { reservation_id: reservationId, execution_id: executionId, job_id: jobId, error: { type: "TaskNotRegistered" } }, connection);
      return;
    }
    const controller = new AbortController();
    const execution = { controller, connection };
    this.#executions.set(executionId, execution);
    void this.runExecution(task, message.args, { reservation_id: reservationId, execution_id: executionId, job_id: jobId }, controller, connection)
      // A transport failure cannot be settled on another socket.
      .catch(() => undefined)
      .finally(() => {
        if (this.#executions.get(executionId) === execution) this.#executions.delete(executionId);
      });
  }

  private async runExecution(task: Task, args: unknown, context: JSONObject, controller: AbortController, connection: net.Socket): Promise<void> {
    if (connection !== this.#connection.socket || connection.destroyed) return;
    await this.#connection.sendEvent("started", context, connection);
    if (connection !== this.#connection.socket || connection.destroyed) return;
    let result: JSONValue;
    try {
      controller.signal.throwIfAborted();
      result = await executeTask(task, args, controller.signal, this.maxResultBytes);
    } catch (error) {
      if (connection === this.#connection.socket) await this.#connection.sendEvent("failed", { ...context, error: errorPayload(error, this.maxErrorBytes) }, connection).catch(() => undefined);
      return;
    }
    if (connection === this.#connection.socket) await this.#connection.sendEvent("succeeded", { ...context, result }, connection);
  }
}
