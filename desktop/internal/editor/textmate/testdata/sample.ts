import { readFile } from "node:fs/promises";
import type { Stats } from "node:fs";

/** A user record. */
export interface User {
  readonly id: number;
  name: string;
  tags?: string[];
}

type Result<T, E = Error> = { ok: true; value: T } | { ok: false; error: E };

enum Level {
  Low = 1,
  High = "high",
}

@sealed
export class Repo<T extends { id: number }> implements Iterable<T> {
  private items = new Map<number, T>();
  static readonly limit = 1_000;

  constructor(private readonly name: string) {}

  get size(): number {
    return this.items.size;
  }

  add(item: T): this {
    this.items.set(item.id, item);
    return this;
  }

  *[Symbol.iterator](): Iterator<T> {
    yield* this.items.values();
  }
}

export async function load(path: string): Promise<Result<User[]>> {
  try {
    const text = await readFile(path, "utf8");
    const users = JSON.parse(text) as User[];
    return { ok: true, value: users.filter((u) => u.name !== "" && /^\w+$/i.test(u.name)) };
  } catch (error: unknown) {
    return { ok: false, error: error instanceof Error ? error : new Error(String(error)) };
  }
}

function sealed(constructor: Function) {
  Object.seal(constructor);
}

// Template strings and numbers.
const greeting = `Hello, ${"world"} at ${new Date().getFullYear()}`;
const mask = 0xff & 0b1010 | 0o17;
let maybe: Stats | undefined = undefined;
export default { greeting, mask, maybe, level: Level.High } satisfies Record<string, unknown>;
