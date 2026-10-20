// An in-memory host for SDK tests: it writes framed messages to a backend
// and decodes what the backend answers, with a bounded wait on every reply.

import { PassThrough } from 'node:stream';
import { encodeFrame, FrameDecoder } from '../src/framing.mjs';

/** Upper bound for any single wait; a broken backend fails fast instead of hanging. */
export const WAIT_MILLISECONDS = 5000;

export class TestHost {
  input = new PassThrough();
  output = new PassThrough();
  errorOutput = new PassThrough();
  messages = [];
  #waiters = [];
  #nextID = 1;
  exitCode;

  constructor(backend) {
    const decoder = new FrameDecoder();
    this.output.on('data', (chunk) => {
      for (const message of decoder.push(chunk)) {
        this.messages.push(message);
        this.#waiters = this.#waiters.filter((waiter) => !waiter(message));
      }
    });
    this.errorOutput.resume();
    this.done = backend.listen({ input: this.input, output: this.output, errorOutput: this.errorOutput, exit: null });
  }

  send(message) {
    this.input.write(encodeFrame({ jsonrpc: '2.0', ...message }));
  }

  /** Sends a request and resolves with the backend's response. */
  request(method, params, id = this.#nextID++) {
    this.send({ id, method, params });
    return this.waitFor((message) => message.id === id && message.method === undefined, `response to ${method}`);
  }

  notify(method, params) {
    this.send({ method, params });
  }

  async initialize(experimental = { litheBuild: { versions: [1] }, litheFunctions: { versions: [1] } }) {
    const response = await this.request('initialize', {
      processId: null,
      rootUri: 'file:///workspace',
      capabilities: { experimental },
    });
    this.notify('initialized', {});
    return response;
  }

  /** Resolves with the first message, past or future, that `matches`. */
  waitFor(matches, description = 'message') {
    const existing = this.messages.find(matches);
    if (existing) return Promise.resolve(existing);
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`Timed out waiting for ${description}.`)), WAIT_MILLISECONDS);
      this.#waiters.push((message) => {
        if (!matches(message)) return false;
        clearTimeout(timer);
        resolve(message);
        return true;
      });
    });
  }

  /** Ends the session and resolves with the backend's exit code. */
  async close() {
    this.input.end();
    return withTimeout(this.done, 'the backend to exit');
  }
}

export function withTimeout(promise, description) {
  let timer;
  return Promise.race([
    promise,
    new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error(`Timed out waiting for ${description}.`)), WAIT_MILLISECONDS);
    }),
  ]).finally(() => clearTimeout(timer));
}

/** A promise with its resolver, for handlers a test releases explicitly. */
export function gate() {
  let open;
  const opened = new Promise((resolve) => {
    open = resolve;
  });
  return { open, opened };
}
