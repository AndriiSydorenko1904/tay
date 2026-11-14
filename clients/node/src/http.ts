import { readFileSync } from "node:fs";
import * as http from "node:http";
import * as https from "node:https";
import { randomUUID } from "node:crypto";
import { ConnectionLost, ProtocolError, ServerError, ValidationError } from "./errors.js";
import {
  errorPayload,
  executeTask,
  extractDurability,
  extractIdentifier,
  extractResult,
  isObject,
  JobHandle,
  Scheduling,
  serverError,
  Task,
} from "./core.js";
import type {
  EnqueueOptions,
  JSONObject,
  JSONValue,
  TaskDefaults,
  TaskHandler,
} from "./types.js";
import { identifier, jsonObject, normalizeJSON, validateEnqueueOptions, validateTaskName } from "./validation.js";

const MAX_RESPONSE_BYTES = 1_048_576;

export interface HTTPOptions {
  requestTimeout?: number;
  caFile?: string;
  certFile?: string;
  keyFile?: string;
  pfxFile?: string;
  passphrase?: string;
}

function positive(value: number, name: string): number {
  if (!Number.isFinite(value) || value <= 0) throw new ValidationError(`${name} must be positive and finite`);
  return value;
}

export class TayHTTP extends Scheduling {
  readonly baseUrl: URL;
  readonly requestTimeout: number;
  readonly #tls: https.RequestOptions;

  constructor(baseUrl = "http://127.0.0.1:8080", options: HTTPOptions = {}) {
    super();
    let parsed: URL;
    try { parsed = new URL(baseUrl); } catch { throw new ValidationError("baseUrl must be an HTTP(S) origin"); }
    if (!(["http:", "https:"].includes(parsed.protocol)) || parsed.pathname !== "/" || parsed.search || parsed.hash || parsed.username || parsed.password) {
      throw new ValidationError("baseUrl must be an HTTP(S) origin");
    }
    const loopback = parsed.hostname === "localhost" || parsed.hostname === "127.0.0.1" || parsed.hostname === "[::1]";
    const pemParts = [options.caFile, options.certFile, options.keyFile];
    if (options.pfxFile && pemParts.some(Boolean)) throw new ValidationError("use either PKCS#12 or PEM credentials");
    if (pemParts.some(Boolean) && !pemParts.every(Boolean)) throw new ValidationError("mTLS requires CA, certificate and key files");
    if (!loopback && (parsed.protocol !== "https:" || (!options.pfxFile && !options.caFile))) {
      throw new ValidationError("remote HTTP targets require HTTPS and mTLS");
    }
    if ((options.pfxFile || options.caFile) && parsed.protocol !== "https:") throw new ValidationError("mTLS requires an HTTPS URL");
    this.baseUrl = parsed;
    this.requestTimeout = positive(options.requestTimeout ?? 30, "requestTimeout");
    this.#tls = options.pfxFile
      ? { pfx: readFileSync(options.pfxFile), ...(options.passphrase === undefined ? {} : { passphrase: options.passphrase }) }
      : options.caFile
        ? { ca: readFileSync(options.caFile), cert: readFileSync(options.certFile!), key: readFileSync(options.keyFile!) }
        : {};
  }

  async enqueue(task: string, args: JSONObject = {}, options: EnqueueOptions = {}): Promise<JobHandle> {
    const payload: JSONObject = {
      task: validateTaskName(task),
      args: jsonObject(args, "enqueue"),
      options: normalizeJSON(validateEnqueueOptions(options)) as JSONObject,
    };
    const reply = await this.request("POST", "/jobs", payload);
    return new JobHandle(extractIdentifier(reply, "job_id", "job"), this, extractDurability(reply));
  }

  async status(jobId: string): Promise<unknown> {
    const reply = await this.request("GET", `/jobs/${encodeURIComponent(identifier(jobId, "jobId"))}`);
    return reply.status ?? reply.job ?? reply;
  }

  async cancel(jobId: string): Promise<unknown> {
    const reply = await this.request("DELETE", `/jobs/${encodeURIComponent(identifier(jobId, "jobId"))}`);
    return reply.status ?? reply;
  }

  async result(jobId: string): Promise<JSONValue> {
    return extractResult(await this.request("GET", `/jobs/${encodeURIComponent(identifier(jobId, "jobId"))}/result`));
  }

  override async scheduleRequest(operation: string, payload: JSONObject): Promise<JSONObject> {
    if (operation === "schedule") return this.request("POST", "/schedules", payload);
    if (operation === "schedules") {
      const suffix = typeof payload.cursor === "string" ? `?cursor=${encodeURIComponent(payload.cursor)}` : "";
      return this.request("GET", `/schedules${suffix}`);
    }
    const id = encodeURIComponent(String(payload.schedule_id));
    return this.request(operation === "cancel_schedule" ? "DELETE" : "GET", `/schedules/${id}`);
  }

  async request(method: string, path: string, body?: JSONObject, headers: Record<string, string> = {}): Promise<JSONObject> {
    const payload = body === undefined ? undefined : Buffer.from(JSON.stringify(normalizeJSON(body)));
    return new Promise<JSONObject>((resolve, reject) => {
      const transport = this.baseUrl.protocol === "https:" ? https : http;
      const request = transport.request(new URL(path, this.baseUrl), {
        method,
        headers: {
          Accept: "application/json",
          ...(payload === undefined ? {} : { "Content-Type": "application/json", "Content-Length": String(payload.length) }),
          ...headers,
        },
        ...this.#tls,
      }, (response) => {
        const chunks: Buffer[] = [];
        let size = 0;
        response.on("data", (chunk: Buffer) => {
          size += chunk.length;
          if (size > MAX_RESPONSE_BYTES) request.destroy(new ProtocolError("Tay HTTP response is too large"));
          else chunks.push(chunk);
        });
        response.on("end", () => {
          const status = response.statusCode ?? 0;
          if ([301, 302, 303, 307, 308].includes(status)) return reject(new ProtocolError("Tay HTTP endpoint redirected the request"));
          const raw = Buffer.concat(chunks);
          if (status === 204 && raw.length === 0) return resolve({});
          let reply: unknown;
          try { reply = JSON.parse(raw.toString("utf8")); } catch { return reject(new ProtocolError("Tay sent invalid HTTP JSON")); }
          if (!isObject(reply)) return reject(new ProtocolError("Tay HTTP response must be a JSON object"));
          if (isObject(reply.error)) return reject(serverError(reply.error));
          if (status < 200 || status >= 300) return reject(new ProtocolError(`Tay HTTP returned unexpected status ${status}`));
          resolve(reply);
        });
      });
      request.setTimeout(this.requestTimeout * 1000, () => request.destroy(new ConnectionLost("Tay HTTP request timed out")));
      request.on("error", (error) => reject(error instanceof ProtocolError || error instanceof ConnectionLost ? error : new ConnectionLost(error.message)));
      if (payload) request.write(payload);
      request.end();
    });
  }
}

export interface HTTPWorkerOptions extends HTTPOptions {
  queue?: string;
  capacity?: number;
  runtimeId?: string;
}

export class TayHTTPWorker extends TayHTTP {
  readonly queue: string;
  readonly capacity: number;
  readonly runtimeId: string;
  readonly tasks = new Map<string, Task>();
  #token: string | undefined;
  #closing = false;
  readonly #executions = new Map<string, { controller: AbortController; promise: Promise<void> }>();

  constructor(baseUrl: string, options: HTTPWorkerOptions = {}) {
    super(baseUrl, options);
    if (this.requestTimeout < 25) throw new ValidationError("HTTP workers require requestTimeout >= 25 seconds");
    this.queue = validateTaskName(options.queue ?? "default");
    this.capacity = options.capacity ?? 1;
    if (!Number.isInteger(this.capacity) || this.capacity < 1 || this.capacity > 256) throw new ValidationError("capacity must be between 1 and 256");
    this.runtimeId = identifier(options.runtimeId ?? `node-${randomUUID().replaceAll("-", "")}`, "runtimeId");
  }

  task(name: string, handler: TaskHandler, defaults: TaskDefaults = {}): Task {
    if (this.tasks.has(name)) throw new ValidationError(`task ${name} is already registered`);
    const task = new Task(this, name, handler, defaults);
    this.tasks.set(task.name, task);
    return task;
  }

  async register(): Promise<void> {
    if (this.#closing) throw new ConnectionLost("HTTP worker is closed");
    if (this.#token) return;
    if (this.tasks.size === 0) throw new ValidationError("register at least one task before starting the worker");
    const reply = await this.request("POST", "/workers", {
      runtime_id: this.runtimeId,
      tasks: [...this.tasks.keys()],
      capacity: this.capacity,
      queue: this.queue,
    });
    const token = reply.worker_token;
    if (typeof token !== "string" || token.length !== 43) throw new ProtocolError("Tay did not return a valid worker token");
    this.#token = token;
    try {
      for (const task of this.tasks.values()) {
        const schedule = task.staticSchedule();
        if (schedule) await this.scheduleRequest("schedule", schedule);
      }
    } catch (error) {
      this.#token = undefined;
      await this.request("DELETE", "/workers", undefined, { Authorization: `Bearer ${token}` }).catch(() => undefined);
      throw error;
    }
  }

  async serve(options: { signal?: AbortSignal } = {}): Promise<void> {
    this.#closing = false;
    try {
      while (!this.#closing && !options.signal?.aborted) {
        try {
          await this.register();
          const message = await this.workerRequest("POST", `/queues/${encodeURIComponent(this.queue)}/claim`);
          await this.handleWorkerMessage(message);
        } catch (error) {
          if (this.#closing || options.signal?.aborted) return;
          if (error instanceof ServerError && error.code === "unknown_worker") { this.#token = undefined; continue; }
          if (error instanceof ConnectionLost || (error instanceof ServerError && error.code === "claim_in_progress")) {
            await new Promise((resolve) => setTimeout(resolve, 1_000));
            continue;
          }
          throw error;
        }
      }
    } finally {
      await this.close();
    }
  }

  async close(): Promise<void> {
    this.#closing = true;
    const executions = [...this.#executions.values()];
    for (const { controller } of executions) controller.abort(new Error("worker closed"));
    await Promise.allSettled(executions.map(({ promise }) => promise));
    this.#executions.clear();
    const token = this.#token;
    this.#token = undefined;
    if (token) await this.request("DELETE", "/workers", undefined, { Authorization: `Bearer ${token}` }).catch(() => undefined);
  }

  private async workerRequest(method: string, path: string, body?: JSONObject, token = this.#token): Promise<JSONObject> {
    if (!token || token !== this.#token) throw new ConnectionLost("worker is not registered or session was retired");
    return this.request(method, path, body, { Authorization: `Bearer ${token}` });
  }

  private async handleWorkerMessage(message: JSONObject): Promise<void> {
    if (message.type === "cancel_execution") {
      if (typeof message.execution_id !== "string") throw new ProtocolError("cancel_execution is missing execution_id");
      this.#executions.get(message.execution_id)?.controller.abort(new Error("execution cancelled"));
      return;
    }
    if (message.type !== "execute") {
      if (Object.keys(message).length > 0) throw new ProtocolError(`unexpected worker event ${String(message.type)}`);
      return;
    }
    const executionId = message.execution_id;
    if (typeof executionId !== "string") throw new ProtocolError("execute is missing execution_id");
    if (this.#executions.has(executionId)) return;
    const controller = new AbortController();
    const token = this.#token;
    const promise = this.execute(message, controller, token).finally(() => {
      if (this.#executions.get(executionId)?.promise === promise) this.#executions.delete(executionId);
    });
    this.#executions.set(executionId, { controller, promise });
  }

  private async execute(message: JSONObject, controller: AbortController, token: string | undefined): Promise<void> {
    const reservationId = message.reservation_id;
    const executionId = message.execution_id;
    const taskName = message.task;
    if (typeof reservationId !== "string" || typeof executionId !== "string" || typeof taskName !== "string") {
      throw new ProtocolError("execute is missing execution context");
    }
    const context: JSONObject = { reservation_id: reservationId, execution_id: executionId };
    const task = this.tasks.get(taskName);
    if (!task) {
      await this.workerRequest("POST", "/workers/complete", { ...context, outcome: "failure", error: { type: "TaskNotRegistered" } }, token);
      return;
    }
    await this.workerRequest("POST", "/workers/started", context, token);
    let completion: JSONObject;
    try {
      const result = await executeTask(task, message.args, controller.signal);
      completion = { ...context, outcome: "success", result };
    } catch (error) {
      completion = { ...context, outcome: "failure", error: errorPayload(error) };
    }
    if (!this.#closing && token === this.#token) await this.workerRequest("POST", "/workers/complete", completion, token);
  }
}
