import { readFileSync, readdirSync } from "node:fs";
import { resolve, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(fileURLToPath(new URL("..", import.meta.url)));
const editor = join(root, "frontend/editor");
function files(directory) {
  return readdirSync(directory, { withFileTypes: true }).flatMap(entry =>
    entry.isDirectory() ? files(join(directory, entry.name)) : [join(directory, entry.name)]);
}
const failures = [];
for (const file of files(join(editor, "src"))) {
  const text = readFileSync(file, "utf8");
  if (/\b(?:from|import)\s*[('"].*(?:macos\/|windows\/|@tauri-apps\/|node:|@\/platform)/.test(text)) {
    failures.push(`${file}: shared editor imports a platform implementation`);
  }
  if (/window\.webkit|__TAURI__|messageHandlers/.test(text)) {
    failures.push(`${file}: shared editor accesses a platform bridge directly`);
  }
}
const shared = JSON.parse(readFileSync(join(editor, "package.json"), "utf8"));
const windows = JSON.parse(readFileSync(join(root, "windows/tauri/package.json"), "utf8"));
const workspace = JSON.parse(readFileSync(join(root, "package.json"), "utf8"));
if (windows.dependencies["@lithe/editor"] !== "workspace:*" ||
    !workspace.workspaces?.includes("frontend/editor") || !workspace.workspaces?.includes("windows/tauri") || windows.workspaces) {
  failures.push("Windows must consume the local shared editor package");
}
const bunConfig = readFileSync(join(root, "bunfig.toml"), "utf8");
if (!/^linker\s*=\s*"isolated"/m.test(bunConfig)) {
  failures.push("Workspace packages must resolve shared sources through the same dependency graph");
}
if (windows.dependencies["monaco-editor"] !== shared.dependencies["monaco-editor"]) {
  failures.push("Both hosts must use the exact same Monaco version");
}
if (failures.length) { console.error(failures.join("\n")); process.exitCode = 1; }
else console.log("Shared editor boundaries and Monaco version verified");
