import { homeDir, join } from "@tauri-apps/api/path";
import { readTextFile, stat } from "@tauri-apps/plugin-fs";

async function readBounded(path: string): Promise<string> {
  if ((await stat(path)).size > 65536) throw new Error("agent.settings.configurationTooLarge");
  const text = await readTextFile(path);
  if (new TextEncoder().encode(text).length > 65536) throw new Error("agent.settings.configurationTooLarge");
  return text;
}

/** Read-only metadata import; never modifies the CLI's files. */
export async function readAgentCliConfiguration(source: "codex" | "claude"): Promise<string> {
  return readBounded(await join(await homeDir(), source === "codex" ? ".codex" : ".claude", source === "codex" ? "config.toml" : "settings.json"));
}

/** One ephemeral connection snapshot. Missing credentials fail instead of using a saved key. */
export async function readAgentCliSnapshot(source: "codex" | "claude"): Promise<{ configuration: string; authentication: string }> {
  const directory = await join(await homeDir(), source === "codex" ? ".codex" : ".claude");
  const [configuration, authentication] = await Promise.all([
    readBounded(await join(directory, source === "codex" ? "config.toml" : "settings.json")),
    source === "codex" ? readBounded(await join(directory, "auth.json")) : Promise.resolve(""),
  ]);
  return { configuration, authentication };
}
