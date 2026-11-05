import { readFileSync, readdirSync } from "node:fs";
import { resolve, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(fileURLToPath(new URL("../..", import.meta.url)));
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
// The macOS host offers plugins gutter icon names (API-27); each needs an SVG in the web editor.
const hostOptions = readFileSync(join(root, "macos/Sources/Lithe/Platform/MacOS/Plugins/PluginEditorHostOptions+macOS.swift"), "utf8");
const offered = /actionIcons:\s*\[([^\]]*)\]/.exec(hostOptions)?.[1].match(/"[a-z0-9-]+"/g)?.map(name => name.slice(1, -1)) ?? [];
const frontend = readFileSync(join(root, "macos/EditorFrontend/main.ts"), "utf8");
const drawn = new Set((/editorActionIcons:\s*\{([^}]*)\}/.exec(frontend)?.[1].match(/"?[a-z][a-z0-9-]*"?(?=\s*:)/g) ?? [])
  .map(name => name.replaceAll('"', "")));
if (!offered.length) failures.push("macOS plugin editor action icons could not be read from the host options");
for (const name of offered) if (!drawn.has(name)) failures.push(`macOS plugin editor action icon "${name}" has no SVG in macos/EditorFrontend/main.ts`);
if (failures.length) { console.error(failures.join("\n")); process.exitCode = 1; }
else console.log("Shared editor boundaries and Monaco version verified");
