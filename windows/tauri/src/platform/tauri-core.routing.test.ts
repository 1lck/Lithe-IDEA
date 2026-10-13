import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { isPlatformDispatcherCommand } from "./tauri-core";

// The routing rule in `tauri-core.ts` must agree with the host: a command that
// `main.rs` registers is invoked directly, and only names the shared
// dispatcher translates reach `platform_invoke`. A drift here fails every call
// to the affected command at runtime, as the Maven dependency tree did (#970).

const mainSource = readFileSync(
  fileURLToPath(new URL("../../src-tauri/src/main.rs", import.meta.url)),
  "utf8",
);

function registeredHostCommands(): string[] {
  const handler = /generate_handler!\[([\s\S]*?)\]/.exec(mainSource);
  if (!handler) throw new Error("main.rs no longer registers commands with generate_handler!");
  return handler[1]!
    .split(",")
    .map((entry) => entry.replace(/\/\/.*$/gm, "").trim())
    .filter(Boolean)
    .map((path) => path.split("::").pop()!);
}

test("main.rs registers the commands this test inspects", () => {
  const commands = registeredHostCommands();
  expect(commands).toContain("platform_invoke");
  expect(commands).toContain("maven_create_dependency_output");
});

test("every registered host command is invoked directly", () => {
  const misrouted = registeredHostCommands().filter(
    (command) => command !== "platform_invoke" && isPlatformDispatcherCommand(command),
  );
  expect(misrouted).toEqual([]);
});

test("dispatcher-owned names stay with the platform dispatcher", () => {
  expect(isPlatformDispatcherCommand("git_status")).toBe(true);
  expect(isPlatformDispatcherCommand("ai_commit_detect")).toBe(true);
  expect(isPlatformDispatcherCommand("maven.dependencyPlan")).toBe(true);
  expect(isPlatformDispatcherCommand("watch_git_repository")).toBe(false);
});
