import { invoke } from "@/platform/tauri-core";

/** Each failed probe adds one existing name, so this bounds a single destination search. */
const MAX_NAME_ATTEMPTS = 512;

/**
 * Names the copy of a project item. Rust Core owns the rule (`workspace.planDuplicate`):
 * `foo.txt` becomes `foo copy.txt`, then `foo copy 2.txt`. This host only reports which
 * planned names already exist, and Core plans again around them.
 *
 * @param exists Reports whether a planned sibling name is taken in the destination.
 */
export async function planDuplicateName(options: {
  name: string;
  isDirectory: boolean;
  exists: (name: string) => boolean | Promise<boolean>;
  caseInsensitive?: boolean;
}): Promise<string> {
  const existing: string[] = [];
  for (let attempt = 0; attempt < MAX_NAME_ATTEMPTS; attempt += 1) {
    const { name } = await invoke<{ name: string }>("workspace.planDuplicate", {
      name: options.name,
      isDirectory: options.isDirectory,
      existing,
      caseInsensitive: options.caseInsensitive ?? false,
    });
    if (!(await options.exists(name))) return name;
    existing.push(name);
  }
  throw new Error(`destination_exists: no free name for ${options.name}`);
}
