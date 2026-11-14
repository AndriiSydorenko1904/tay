import { ProtocolError, ValidationError } from "./errors.js";
import type { JSONObject } from "./types.js";
import { normalizeJSON } from "./validation.js";

export const PROTOCOL_VERSION = 1;
export const DEFAULT_MAX_FRAME_BYTES = 1_048_576;

export interface Envelope extends JSONObject {
  version: number;
  type: string;
  request_id: string;
}

export function validateEnvelope(value: unknown, incoming = false): Envelope {
  const normalized = normalizeJSON(value);
  if (normalized === null || Array.isArray(normalized) || typeof normalized !== "object") {
    throw new ProtocolError("protocol envelope must be an object");
  }
  const envelope = normalized as JSONObject;
  const version = envelope.version ?? (incoming ? envelope.v : undefined);
  if (version !== PROTOCOL_VERSION) throw new ProtocolError(`unsupported protocol version ${String(version)}`);
  if (typeof envelope.type !== "string" || !envelope.type || Buffer.byteLength(envelope.type) > 64) {
    throw new ProtocolError("protocol envelope requires a bounded non-empty string type");
  }
  if (typeof envelope.request_id !== "string" || !envelope.request_id || Buffer.byteLength(envelope.request_id) > 128) {
    throw new ProtocolError("protocol envelope requires a bounded non-empty request_id");
  }
  return envelope as Envelope;
}

export function encodeFrame(value: unknown, maxFrameBytes = DEFAULT_MAX_FRAME_BYTES): Buffer {
  if (!Number.isInteger(maxFrameBytes) || maxFrameBytes < 1) throw new ValidationError("maxFrameBytes must be positive");
  const envelope = validateEnvelope(value);
  const payload = Buffer.from(JSON.stringify(envelope), "utf8");
  if (payload.length === 0 || payload.length > maxFrameBytes) {
    throw new ProtocolError(`protocol payload size ${payload.length} exceeds limit ${maxFrameBytes}`);
  }
  const frame = Buffer.allocUnsafe(payload.length + 4);
  frame.writeUInt32BE(payload.length, 0);
  payload.copy(frame, 4);
  return frame;
}

export function decodePayload(payload: Buffer, maxFrameBytes = DEFAULT_MAX_FRAME_BYTES): Envelope {
  if (payload.length === 0 || payload.length > maxFrameBytes) throw new ProtocolError("invalid protocol frame length");
  let parsed: unknown;
  try {
    parsed = JSON.parse(payload.toString("utf8"));
  } catch {
    throw new ProtocolError("protocol frame contains malformed JSON");
  }
  return validateEnvelope(parsed, true);
}

export class FrameDecoder {
  #buffer: Buffer<ArrayBufferLike> = Buffer.alloc(0);
  readonly maxFrameBytes: number;

  constructor(maxFrameBytes = DEFAULT_MAX_FRAME_BYTES) {
    this.maxFrameBytes = maxFrameBytes;
  }

  push(chunk: Buffer): Envelope[] {
    this.#buffer = this.#buffer.length === 0 ? chunk : Buffer.concat([this.#buffer, chunk]);
    const messages: Envelope[] = [];
    while (this.#buffer.length >= 4) {
      const length = this.#buffer.readUInt32BE(0);
      if (length === 0 || length > this.maxFrameBytes) throw new ProtocolError(`protocol frame length ${length} is outside limits`);
      if (this.#buffer.length < length + 4) break;
      messages.push(decodePayload(this.#buffer.subarray(4, length + 4), this.maxFrameBytes));
      this.#buffer = this.#buffer.subarray(length + 4);
    }
    return messages;
  }
}
