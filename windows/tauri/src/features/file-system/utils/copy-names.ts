import { invoke } from "@/platform/tauri-core";

/** Each failed probe adds one existing name, so this bounds a single destination search. */
const MAX_NAME_ATTEMPTS = 512;

/** True when a provider reports that the destination name appeared after it was planned. */
export const isDestinationExists = (error: unknown): boolean =>
  String(error instanceof Error ? error.message : error).includes("destination_exists");

/**
 * Names the copy of a project item and runs `create` with it. Rust Core owns the rule
 * (`workspace.planDuplicate`): `foo.txt` becomes `foo copy.txt`, then `foo copy 2.txt`.
 * `listNames` reads the names that actually exist in the destination directory from the
 * provider (never the in-memory tree). When `create` fails with `destination_exists` the
 * name is added to the facts and Core plans again.
 */
export async function duplicateWithPlannedName<T>(options: {
  name: string;
  isDirectory: boolean;
  listNames: () => Promise<string[]>;
  create: (name: string) => Promise<T>;
  caseInsensitive?: boolean;
}): Promise<{ name: string; result: T }> {
  const existing = [...(await options.listNames())];
  for (let attempt = 0; attempt < MAX_NAME_ATTEMPTS; attempt += 1) {
    const { name } = await invoke<{ name: string }>("workspace.planDuplicate", {
      name: options.name,
      isDirectory: options.isDirectory,
      existing,
      caseInsensitive: options.caseInsensitive ?? false,
    });
    try {
      return { name, result: await options.create(name) };
    } catch (error) {
      if (!isDestinationExists(error) || existing.includes(name)) throw error;
      existing.push(name);
    }
  }
  throw new Error(`destination_exists: no free name for ${options.name}`);
}
