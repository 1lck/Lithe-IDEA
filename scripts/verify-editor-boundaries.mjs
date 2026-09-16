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
if (windows.dependencies["@lithe/editor"] !== "workspace:*" || !windows.workspaces?.includes("../../frontend/editor")) {
  failures.push("Windows must consume the local shared editor package");
}
const bunConfig = readFileSync(join(root, "windows/tauri/bunfig.toml"), "utf8");
if (!/^linker\s*=\s*"isolated"/m.test(bunConfig)) {
  failures.push("Windows must give external editor workspace sources resolvable dependencies");
}
if (windows.dependencies["monaco-editor"] !== shared.dependencies["monaco-editor"]) {
  failures.push("Both hosts must use the exact same Monaco version");
}
if (failures.length) { console.error(failures.join("\n")); process.exitCode = 1; }
else console.log("Shared editor boundaries and Monaco version verified");
