import { isAbsolute, join, resolve } from "node:path";
import { accessSync, constants, statSync } from "node:fs";
import { ValidationError } from "./errors.js";
import type {
  Durability,
  EnqueueOptions,
  EveryScheduleOptions,
  JSONObject,
  JSONValue,
} from "./types.js";

const MAX_SAFE_JSON_INTEGER = Number.MAX_SAFE_INTEGER;
export const MAX_SOCKET_PATH_BYTES = 100;
const encoder = new TextEncoder();
const optionNames = new Set([
  "id",
  "submission_id",
  "delay",
  "delay_ms",
  "run_at",
  "retries",
  "timeout",
  "timeout_ms",
  "backoff",
  "queue",
  "durability",
]);

export function normalizeJSON(
  value: unknown,
  depth = 0,
  seen = new Set<object>(),
): JSONValue {
  if (depth > 32) throw new ValidationError("JSON value exceeds maximum nesting depth (32)");
  if (value === null || typeof value === "boolean" || typeof value === "string") return value;
  if (typeof value === "number") {
    if (!Number.isFinite(value)) throw new ValidationError("JSON numbers must be finite");
    return value;
  }
  if (Array.isArray(value)) {
    if (value.length > 10_000) throw new ValidationError("JSON list has more than 10000 items");
    if (seen.has(value)) throw new ValidationError("cyclic values are not JSON-safe");
    seen.add(value);
    try {
      return value.map((item) => normalizeJSON(item, depth + 1, seen));
    } finally {
      seen.delete(value);
    }
  }
  if (typeof value === "object" && Object.getPrototypeOf(value) === Object.prototype) {
    const source = value as Record<string, unknown>;
    const entries = Object.entries(source);
    if (entries.length > 10_000) throw new ValidationError("JSON object has more than 10000 entries");
    if (seen.has(source)) throw new ValidationError("cyclic values are not JSON-safe");
    seen.add(source);
    try {
      return Object.fromEntries(entries.map(([key, item]) => [key, normalizeJSON(item, depth + 1, seen)]));
    } finally {
      seen.delete(source);
    }
  }
  throw new ValidationError(`${typeof value} is not JSON-safe; pass IDs and plain JSON values instead`);
}

export function jsonObject(value: unknown, operation: string): JSONObject {
  const normalized = normalizeJSON(value ?? {});
  if (normalized === null || Array.isArray(normalized) || typeof normalized !== "object") {
    throw new ValidationError(`${operation} args must be a JSON object`);
  }
  return normalized;
}

export function validateTaskName(name: unknown): string {
  if (typeof name !== "string" || name.length === 0) throw new ValidationError("task name must be a non-empty string");
  if (encoder.encode(name).length > 255) throw new ValidationError("task name exceeds 255 UTF-8 bytes");
  if ([...name].some((character) => character.codePointAt(0)! < 0x20)) {
    throw new ValidationError("task name cannot contain control characters");
  }
  return name;
}

export function identifier(value: unknown, name: string): string {
  if (typeof value !== "string" || value.length === 0 || encoder.encode(value).length > 128 || value.includes("\0")) {
    throw new ValidationError(`${name} must be a non-empty UTF-8 string of at most 128 bytes`);
  }
  return value;
}

function milliseconds(value: unknown, max: number, min: number, name: string): void {
  if (typeof value !== "number" || !Number.isFinite(value) || value < 0 || value > max / 1000) {
    throw new ValidationError(`invalid ${name}`);
  }
  const converted = Math.round(value * 1000);
  if (converted < min || converted > max) throw new ValidationError(`invalid ${name}`);
}

export function validateDurability(value: unknown): asserts value is Durability | undefined {
  if (value !== undefined && value !== "persistent" && value !== "volatile") {
    throw new ValidationError("durability must be persistent or volatile");
  }
}

export function validateEnqueueOptions(raw: EnqueueOptions = {}): EnqueueOptions {
  const normalized = normalizeJSON(raw) as Record<string, JSONValue>;
  const nullableAliases = new Set(["id", "submission_id", "delay", "delay_ms", "run_at", "timeout", "timeout_ms", "backoff", "durability"]);
  const options = Object.fromEntries(
    Object.entries(normalized).filter(([name, value]) => value !== null || !nullableAliases.has(name)),
  ) as Record<string, JSONValue>;
  const unknown = Object.keys(options).filter((name) => !optionNames.has(name)).sort();
  if (unknown[0]) throw new ValidationError(`unsupported enqueue option: ${unknown[0]}`);
  if (options.id !== undefined && (typeof options.id !== "string" || !/^(?!0{32})[0-9a-f]{32}$/.test(options.id))) {
    throw new ValidationError("id must be a nonzero lowercase 128-bit hex ID");
  }
  if (options.submission_id !== undefined) {
    identifier(options.submission_id, "submission_id");
    if (options.id !== undefined) throw new ValidationError("id and submission_id cannot be combined");
  }
  if (options.delay !== undefined) milliseconds(options.delay, MAX_SAFE_JSON_INTEGER, 0, "delay");
  if (options.delay_ms !== undefined && (typeof options.delay_ms !== "number" || !Number.isSafeInteger(options.delay_ms) || options.delay_ms < 0)) {
    throw new ValidationError("invalid delay_ms");
  }
  if (options.delay !== undefined && options.delay_ms !== undefined) throw new ValidationError("delay and delay_ms cannot be combined");
  if (options.run_at !== undefined && (typeof options.run_at !== "number" || !Number.isSafeInteger(options.run_at) || options.run_at < 0)) {
    throw new ValidationError("invalid run_at");
  }
  if (options.run_at !== undefined && (options.delay !== undefined || options.delay_ms !== undefined)) {
    throw new ValidationError("run_at cannot be combined with delay");
  }
  if (options.timeout !== undefined) milliseconds(options.timeout, 86_400_000, 1, "timeout");
  if (options.timeout_ms !== undefined && (typeof options.timeout_ms !== "number" || !Number.isInteger(options.timeout_ms) || options.timeout_ms < 1 || options.timeout_ms > 86_400_000)) {
    throw new ValidationError("invalid timeout_ms");
  }
  if (options.timeout !== undefined && options.timeout_ms !== undefined) throw new ValidationError("timeout and timeout_ms cannot be combined");
  if (options.retries !== undefined && (typeof options.retries !== "number" || !Number.isInteger(options.retries) || options.retries < 0 || options.retries > 65_534)) {
    throw new ValidationError("retries must be an integer in 0..65534");
  }
  if (options.backoff !== undefined && options.backoff !== "exponential") {
    throw new ValidationError("Protocol v1 supports only backoff='exponential'");
  }
  if (options.queue !== undefined && (typeof options.queue !== "string" || options.queue.length === 0 || options.queue.includes("\0") || encoder.encode(options.queue).length > 255)) {
    throw new ValidationError("invalid queue");
  }
  validateDurability(options.durability);
  return options as EnqueueOptions;
}

export function validateEvery(options: EveryScheduleOptions): Record<string, number> {
  const units = ["seconds", "minutes", "hours", "days"] as const;
  const present = units.filter((unit) => options[unit] !== undefined);
  if (present.length !== 1) throw new ValidationError("every requires exactly one positive time unit");
  const unit = present[0]!;
  const amount = options[unit]!;
  const multiplier = { seconds: 1_000, minutes: 60_000, hours: 3_600_000, days: 86_400_000 }[unit];
  if (typeof amount !== "number" || !Number.isFinite(amount) || amount <= 0 || amount * multiplier < 0.5 || amount * multiplier > MAX_SAFE_JSON_INTEGER) {
    throw new ValidationError(`every.${unit} must be a positive finite number`);
  }
  return { [unit]: amount };
}

function usableDirectory(path: string): boolean {
  try {
    return statSync(path).isDirectory() && (accessSync(path, constants.W_OK | constants.X_OK), true);
  } catch {
    return false;
  }
}

function validSocketPath(path: string): boolean {
  return path.length > 0 && isAbsolute(path) && !path.includes("\0") && encoder.encode(path).length <= MAX_SOCKET_PATH_BYTES;
}

export function resolveSocketPath(explicit?: string, environment: NodeJS.ProcessEnv = process.env, uid = process.getuid?.()): string {
  const validate = (path: string): string => {
    const normalized = resolve(path);
    if (!validSocketPath(path) || !validSocketPath(normalized)) {
      throw new ValidationError("socketPath must be an absolute UTF-8 path of at most 100 bytes");
    }
    return normalized;
  };
  if (explicit !== undefined) return validate(explicit);
  if (environment.TAY_SOCKET_PATH) return validate(environment.TAY_SOCKET_PATH);
  try {
    if (statSync("/run/tay").isDirectory()) return "/run/tay/tay.sock";
  } catch { /* not present */ }
  if (!Number.isInteger(uid) || uid! < 0) throw new ValidationError("a non-negative Unix UID is required for socket discovery");
  if (environment.XDG_RUNTIME_DIR && usableDirectory(environment.XDG_RUNTIME_DIR)) {
    const candidate = join(environment.XDG_RUNTIME_DIR, "tay", "tay.sock");
    if (validSocketPath(candidate)) return candidate;
  }
  if (environment.TMPDIR && usableDirectory(environment.TMPDIR)) {
    const candidate = join(environment.TMPDIR, `tay-${uid}`, "tay.sock");
    if (validSocketPath(candidate)) return candidate;
  }
  if (usableDirectory("/tmp")) return validate(join("/tmp", `tay-${uid}`, "tay.sock"));
  throw new ValidationError("no usable Tay socket directory: check XDG_RUNTIME_DIR, TMPDIR and /tmp");
}
