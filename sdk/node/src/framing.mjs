// LSP base-protocol framing: `Content-Length` headers followed by a UTF-8
// JSON body. Lithe talks to every plugin backend this way, so the SDK owns
// the framing and plugin code never writes to stdout itself.

const HEADER_END = Buffer.from('\r\n\r\n', 'ascii');

/** Largest header block accepted from the host. */
const MAX_HEADER_BYTES = 8192;

/** Largest body accepted from the host. Larger frames end the session. */
export const MAX_FRAME_BYTES = 64 * 1024 * 1024;

/** Stands for a body that is not JSON; compared by identity, so no host message can mimic it. */
export const MALFORMED = Object.freeze({ malformed: true });

/** A framing error the session cannot recover from. */
export class FramingError extends Error {}

/** Incrementally splits a byte stream into decoded JSON-RPC messages. */
export class FrameDecoder {
  #buffer = Buffer.alloc(0);

  /**
   * Appends `chunk` and returns every complete message it finished. A body
   * that is not JSON is returned as `MALFORMED` so the caller can
   * report it without losing the framing position.
   */
  push(chunk) {
    this.#buffer = this.#buffer.length === 0 ? Buffer.from(chunk) : Buffer.concat([this.#buffer, chunk]);
    const messages = [];
    for (;;) {
      const headerEnd = this.#buffer.indexOf(HEADER_END);
      // The same bound whether the header arrived whole or in pieces.
      if (headerEnd > MAX_HEADER_BYTES || (headerEnd < 0 && this.#buffer.length > MAX_HEADER_BYTES)) {
        throw new FramingError('The message header is too long.');
      }
      if (headerEnd < 0) return messages;
      const length = contentLength(this.#buffer.subarray(0, headerEnd).toString('ascii'));
      const bodyStart = headerEnd + HEADER_END.length;
      if (this.#buffer.length < bodyStart + length) {
        return messages;
      }
      const body = this.#buffer.subarray(bodyStart, bodyStart + length).toString('utf8');
      this.#buffer = this.#buffer.subarray(bodyStart + length);
      try {
        messages.push(JSON.parse(body));
      } catch {
        messages.push(MALFORMED);
      }
    }
  }
}

function contentLength(header) {
  for (const line of header.split('\r\n')) {
    const separator = line.indexOf(':');
    if (separator < 0) continue;
    if (line.slice(0, separator).trim().toLowerCase() !== 'content-length') continue;
    const value = line.slice(separator + 1).trim();
    if (!/^\d+$/.test(value)) break;
    const length = Number(value);
    if (length > MAX_FRAME_BYTES) {
      throw new FramingError(`A message of ${length} bytes exceeds the ${MAX_FRAME_BYTES}-byte limit.`);
    }
    return length;
  }
  throw new FramingError('A message has no valid Content-Length header.');
}

/** Encodes one JSON-RPC message as a complete frame. */
export function encodeFrame(message) {
  const body = Buffer.from(JSON.stringify(message), 'utf8');
  return Buffer.concat([Buffer.from(`Content-Length: ${body.length}\r\n\r\n`, 'ascii'), body]);
}
