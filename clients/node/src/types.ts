export type JSONPrimitive = null | boolean | number | string;
export type JSONValue = JSONPrimitive | JSONValue[] | { [key: string]: JSONValue };
export type JSONObject = { [key: string]: JSONValue };
export type Durability = "persistent" | "volatile";
export type Backoff = "exponential";
export type CatchUp = "latest" | "all";
export type Overlap = "allow" | "skip" | "queue";

export interface EnqueueOptions {
  id?: string;
  submission_id?: string;
  delay?: number;
  delay_ms?: number;
  run_at?: number;
  retries?: number | "infinity";
  timeout?: number;
  timeout_ms?: number;
  backoff?: Backoff;
  queue?: string;
  durability?: Durability;
  availability_key?: string;
}

export interface ScheduleOptions extends EnqueueOptions {
  args?: JSONObject;
  declarationId?: string;
  catchUp?: CatchUp;
  overlap?: Overlap;
  delay?: number;
  startAt?: number;
}

export interface CronScheduleOptions extends ScheduleOptions {
  cron: string;
  timezone?: string;
}

export interface EveryScheduleOptions extends ScheduleOptions {
  seconds?: number;
  minutes?: number;
  hours?: number;
  days?: number;
}

export interface TaskDefaults {
  retries?: number | "infinity";
  backoff?: Backoff;
  durability?: Durability;
  availability_key?: string;
  cron?: string;
  every?: Omit<EveryScheduleOptions, keyof ScheduleOptions>;
  overlap?: Overlap;
  declarationId?: string;
}

export type TaskHandler = (
  args: Readonly<JSONObject>,
  signal: AbortSignal,
) => JSONValue | Promise<JSONValue>;
