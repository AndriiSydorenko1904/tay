import {
  JobCancelled,
  ProtocolError,
  RemoteTaskError,
  ResultMissing,
  ServerError,
  ValidationError,
} from "./errors.js";
import type {
  CronScheduleOptions,
  Durability,
  EnqueueOptions,
  EveryScheduleOptions,
  JSONObject,
  JSONValue,
  Overlap,
  TaskDefaults,
  TaskHandler,
} from "./types.js";
import {
  identifier,
  jsonObject,
  normalizeJSON,
  validateEnqueueOptions,
  validateEvery,
  validateTaskName,
} from "./validation.js";

export interface ResultSource {
  result(jobId: string): Promise<JSONValue>;
  status(jobId: string): Promise<unknown>;
  cancel(jobId: string): Promise<unknown>;
}

export class JobHandle {
  readonly id: string;
  readonly durability: Durability | undefined;
  readonly #source: ResultSource;

  constructor(id: string, source: ResultSource, durability?: Durability) {
    this.id = id;
    this.#source = source;
    this.durability = durability;
  }

  status(): Promise<unknown> { return this.#source.status(this.id); }
  cancel(): Promise<unknown> { return this.#source.cancel(this.id); }
  result(): Promise<JSONValue> { return this.#source.result(this.id); }

  async waitResult(options: { timeout?: number; pollInterval?: number; signal?: AbortSignal } = {}): Promise<JSONValue> {
    const timeout = options.timeout ?? 30;
    const pollInterval = options.pollInterval ?? 0.1;
    if (!Number.isFinite(timeout) || timeout <= 0) throw new ValidationError("timeout must be positive and finite");
    if (!Number.isFinite(pollInterval) || pollInterval <= 0) throw new ValidationError("pollInterval must be positive and finite");
    const deadline = performance.now() + timeout * 1000;
    for (;;) {
      options.signal?.throwIfAborted();
      try {
        return await this.result();
      } catch (error) {
        if (!(error instanceof ServerError) || error.code !== "result_not_ready") throw error;
      }
      const remaining = deadline - performance.now();
      if (remaining <= 0) throw new DOMException(`Tay result wait exceeded ${timeout}s`, "TimeoutError");
      await new Promise<void>((resolve, reject) => {
        const aborted = () => { clearTimeout(timer); reject(options.signal!.reason); };
        const timer = setTimeout(() => {
          options.signal?.removeEventListener("abort", aborted);
          resolve();
        }, Math.min(remaining, pollInterval * 1000));
        options.signal?.addEventListener("abort", aborted, { once: true });
      });
    }
  }
}

export interface SchedulerTransport {
  scheduleRequest(operation: string, payload: JSONObject): Promise<JSONObject>;
}

export class ScheduleHandle {
  readonly id: string;
  readonly #transport: Scheduling;

  constructor(id: string, transport: Scheduling) {
    this.id = id;
    this.#transport = transport;
  }

  cancel(): Promise<unknown> { return this.#transport.cancelSchedule(this.id); }
  status(): Promise<JSONObject> { return this.#transport.getSchedule(this.id); }
}

export abstract class Scheduling implements SchedulerTransport {
  abstract scheduleRequest(operation: string, payload: JSONObject): Promise<JSONObject>;

  async schedule(task: string | Task, settings: CronScheduleOptions): Promise<ScheduleHandle> {
    if (typeof settings.cron !== "string" || !settings.cron.trim() || Buffer.byteLength(settings.cron) > 128) {
      throw new ValidationError("cron must be a non-empty string no longer than 128 bytes");
    }
    const timezone = settings.timezone ?? "+00";
    if (!/^(?:UTC|Z|[+-](?:[01]\d|2[0-3])(?::[0-5]\d)?)$/.test(timezone)) {
      throw new ValidationError("timezone must be UTC, Z, or an offset such as +01 or -02:30");
    }
    const payload = this.schedulePayload(task, settings);
    payload.cron = settings.cron;
    payload.timezone = timezone;
    return this.declareSchedule(payload);
  }

  async every(task: string | Task, settings: EveryScheduleOptions): Promise<ScheduleHandle> {
    const payload = this.schedulePayload(task, settings);
    payload.every = validateEvery(settings) as JSONObject;
    return this.declareSchedule(payload);
  }

  protected schedulePayload(task: string | Task, settings: CronScheduleOptions | EveryScheduleOptions): JSONObject {
    const declarationId = settings.declarationId;
    if (declarationId !== undefined) identifier(declarationId, "declarationId");
    const catchUp = settings.catchUp ?? "latest";
    if (catchUp !== "latest" && catchUp !== "all") throw new ValidationError("catchUp must be latest or all");
    if (settings.overlap !== undefined && !["allow", "skip", "queue"].includes(settings.overlap)) {
      throw new ValidationError("overlap must be allow, skip, or queue");
    }
    if (settings.delay !== undefined && (!Number.isFinite(settings.delay) || settings.delay < 0)) {
      throw new ValidationError("delay must be a finite non-negative number of seconds");
    }
    if (settings.startAt !== undefined && (!Number.isSafeInteger(settings.startAt) || settings.startAt < 0)) {
      throw new ValidationError("startAt must be a non-negative UTC millisecond timestamp");
    }
    if (settings.delay !== undefined && settings.startAt !== undefined) throw new ValidationError("pass either delay or startAt, not both");
    const reserved = new Set(["args", "declarationId", "catchUp", "overlap", "delay", "startAt", "cron", "timezone", "seconds", "minutes", "hours", "days"]);
    const jobOptions = Object.fromEntries(Object.entries(settings).filter(([key]) => !reserved.has(key))) as EnqueueOptions;
    const payload: JSONObject = {
      task: task instanceof Task ? task.name : validateTaskName(task),
      args: jsonObject(settings.args, "schedule"),
      catch_up: catchUp,
      options: normalizeJSON(validateEnqueueOptions(jobOptions)) as JSONObject,
    };
    if (declarationId !== undefined) payload.declaration_id = declarationId;
    if (settings.overlap !== undefined) payload.overlap = settings.overlap;
    if (settings.delay !== undefined) payload.delay = settings.delay;
    if (settings.startAt !== undefined) payload.start_at = settings.startAt;
    return payload;
  }

  protected async declareSchedule(payload: JSONObject): Promise<ScheduleHandle> {
    const reply = await this.scheduleRequest("schedule", payload);
    return new ScheduleHandle(extractIdentifier(reply, "schedule_id", "schedule"), this);
  }

  async cancelSchedule(scheduleId: string): Promise<unknown> {
    identifier(scheduleId, "scheduleId");
    const reply = await this.scheduleRequest("cancel_schedule", { schedule_id: scheduleId });
    return reply.schedule ?? reply.status ?? reply;
  }

  async getSchedule(scheduleId: string): Promise<JSONObject> {
    identifier(scheduleId, "scheduleId");
    const reply = await this.scheduleRequest("schedule_status", { schedule_id: scheduleId });
    if (!isObject(reply.schedule)) throw new ProtocolError("Tay omitted the schedule object");
    return reply.schedule;
  }

  async schedules(): Promise<JSONObject[]> {
    const collected: JSONObject[] = [];
    let cursor: string | undefined;
    for (;;) {
      const reply = await this.scheduleRequest("schedules", cursor ? { cursor } : {});
      if (!Array.isArray(reply.schedules) || !reply.schedules.every(isObject)) throw new ProtocolError("Tay omitted the schedule list");
      collected.push(...reply.schedules);
      if (reply.next_cursor === undefined || reply.next_cursor === null) return collected;
      if (typeof reply.next_cursor !== "string" || !reply.next_cursor || (cursor !== undefined && reply.next_cursor <= cursor)) {
        throw new ProtocolError("Tay returned an invalid schedule cursor");
      }
      cursor = reply.next_cursor;
    }
  }
}

export class Task {
  readonly name: string;
  readonly handler: TaskHandler;
  readonly defaults: Readonly<TaskDefaults>;
  readonly #producer: { enqueue(task: string, args?: JSONObject, options?: EnqueueOptions): Promise<JobHandle> };

  constructor(producer: { enqueue(task: string, args?: JSONObject, options?: EnqueueOptions): Promise<JobHandle> }, name: string, handler: TaskHandler, defaults: TaskDefaults = {}) {
    this.#producer = producer;
    this.name = validateTaskName(name);
    if (typeof handler !== "function") throw new ValidationError("task handler must be a function");
    this.handler = handler;
    validateEnqueueOptions(Object.fromEntries(Object.entries(defaults).filter(([key]) => ["retries", "backoff", "durability"].includes(key))) as EnqueueOptions);
    this.defaults = Object.freeze({ ...defaults });
  }

  enqueue(args: JSONObject = {}, options: EnqueueOptions = {}): Promise<JobHandle> {
    const merged: EnqueueOptions = {
      ...(this.defaults.retries === undefined ? {} : { retries: this.defaults.retries }),
      ...(this.defaults.backoff === undefined ? {} : { backoff: this.defaults.backoff }),
      ...(this.defaults.durability === undefined ? {} : { durability: this.defaults.durability }),
      ...options,
    };
    return this.#producer.enqueue(this.name, args, merged);
  }

  staticSchedule(): JSONObject | undefined {
    if (this.defaults.cron === undefined && this.defaults.every === undefined) return undefined;
    const declarationId = this.defaults.declarationId ?? `task:${this.name}`;
    const base: JSONObject = {
      task: this.name,
      args: {},
      declaration_id: declarationId,
      catch_up: "latest",
      overlap: this.defaults.overlap ?? "skip",
      options: normalizeJSON({
        ...(this.defaults.retries === undefined ? {} : { retries: this.defaults.retries }),
        ...(this.defaults.backoff === undefined ? {} : { backoff: this.defaults.backoff }),
        ...(this.defaults.durability === undefined ? {} : { durability: this.defaults.durability }),
      }) as JSONObject,
    };
    if (this.defaults.cron !== undefined) { base.cron = this.defaults.cron; base.timezone = "+00"; }
    else base.every = validateEvery(this.defaults.every! as EveryScheduleOptions) as JSONObject;
    return base;
  }
}

export function isObject(value: unknown): value is JSONObject {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

export function serverError(payload: unknown): ServerError {
  if (!isObject(payload)) return new ServerError(String(payload));
  const codeValue = payload.code ?? payload.type;
  const code = typeof codeValue === "string" ? codeValue : undefined;
  const messageValue = payload.message ?? payload.reason;
  const message = typeof messageValue === "string" && messageValue ? messageValue : code ? `Tay rejected the request (${code})` : "Tay rejected the request";
  const options = { ...(code === undefined ? {} : { code }), details: payload };
  if (code === "task_cancelled") return new JobCancelled(message, options);
  if (code === "result_missing") return new ResultMissing(message, options);
  if (payload.remote_task || code === "task_failed" || code === "TaskFailed") return new RemoteTaskError(message, options);
  return new ServerError(message, options);
}

export function extractIdentifier(reply: JSONObject, field: string, nestedField: string): string {
  const nested = isObject(reply[nestedField]) ? reply[nestedField] : undefined;
  const value = reply[field] ?? nested?.id;
  if (typeof value !== "string" || !value) throw new ProtocolError(`Tay reply did not include a valid ${field}`);
  return value;
}

export function extractDurability(reply: JSONObject): Durability | undefined {
  const value = isObject(reply.job) ? reply.job.durability : undefined;
  return value === "persistent" || value === "volatile" ? value : undefined;
}

export function extractResult(reply: JSONObject): JSONValue {
  if (reply.error) throw serverError(reply.error);
  if (!("result" in reply)) throw new ProtocolError("Tay result reply did not include a result field");
  return reply.result!;
}

export function errorPayload(error: unknown, maxBytes = 8_192): JSONObject {
  const record: JSONObject = {
    type: error instanceof Error ? error.name : "Error",
    message: error instanceof Error ? error.message : String(error),
  };
  if (error instanceof Error && error.stack) record.stack = error.stack;
  let encoded = Buffer.from(JSON.stringify(record));
  if (encoded.length <= maxBytes) return record;
  delete record.stack;
  encoded = Buffer.from(JSON.stringify(record));
  if (encoded.length <= maxBytes) return record;
  const message = String(record.message);
  record.message = Buffer.from(message).subarray(0, Math.max(0, maxBytes - 128)).toString("utf8");
  return record;
}

export async function executeTask(task: Task, args: unknown, signal: AbortSignal, maxResultBytes = 65_536): Promise<JSONValue> {
  const value = normalizeJSON(await task.handler(jsonObject(args, "execute"), signal));
  const size = Buffer.byteLength(JSON.stringify(value));
  if (size > maxResultBytes) throw new ValidationError(`task result exceeds ${maxResultBytes} bytes`);
  return value;
}
