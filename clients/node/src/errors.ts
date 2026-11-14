export class TayError extends Error {
  override name = "TayError";
}

export class ValidationError extends TayError {
  override name = "ValidationError";
}

export class ProtocolError extends TayError {
  override name = "ProtocolError";
}

export class ConnectionLost extends TayError {
  override name = "ConnectionLost";
}

export class ModeError extends TayError {
  override name = "ModeError";
}

export class TaskRegistrationError extends TayError {
  override name = "TaskRegistrationError";
}

export class TaskNotRegistered extends TayError {
  override name = "TaskNotRegistered";
}

export class ResultTooLarge extends ValidationError {
  override name = "ResultTooLarge";
}

export class ServerError extends TayError {
  override name = "ServerError";
  readonly code: string | undefined;
  readonly details: Readonly<Record<string, unknown>> | undefined;

  constructor(
    message: string,
    options: { code?: string; details?: Readonly<Record<string, unknown>> } = {},
  ) {
    super(message);
    this.code = options.code;
    this.details = options.details;
  }
}

export class RemoteTaskError extends ServerError {
  override name = "RemoteTaskError";
}

export class JobCancelled extends ServerError {
  override name = "JobCancelled";
}

export class ResultMissing extends ServerError {
  override name = "ResultMissing";
}
