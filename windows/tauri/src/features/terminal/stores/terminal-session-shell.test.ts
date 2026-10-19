import { describe, expect, test } from "bun:test";
import { createTerminalStore } from "./terminal.store";

/**
 * Path insertion quotes per shell family, so the launched shell has to survive on
 * the session. Regression: the initialization path stored the connection and the
 * directory but not the shell, so every entry point read `undefined` and quoted
 * as cmd — PowerShell file names containing `$()` then still executed.
 */
describe("terminal session shell ownership", () => {
  test("keeps the shell recorded after initialization", () => {
    const store = createTerminalStore();
    const { updateSession, getSession } = store.getState().actions;

    updateSession("terminal-1", {
      connectionId: "connection-1",
      currentDirectory: "C:\\work\\proj",
      shell: "powershell",
    });

    expect(getSession("terminal-1")?.shell).toBe("powershell");
  });

  test("keeps the connection and directory written alongside the shell", () => {
    const store = createTerminalStore();
    const { updateSession, getSession } = store.getState().actions;

    updateSession("terminal-1", {
      connectionId: "connection-1",
      currentDirectory: "C:\\work\\proj",
      shell: "bash",
    });

    expect(getSession("terminal-1")).toMatchObject({
      connectionId: "connection-1",
      currentDirectory: "C:\\work\\proj",
      shell: "bash",
    });
  });

  // A later update without a shell must not erase the recorded one, otherwise a
  // directory change would silently drop the quoting policy back to cmd.
  test("does not clear the shell when a later update omits it", () => {
    const store = createTerminalStore();
    const { updateSession, getSession } = store.getState().actions;

    updateSession("terminal-1", { shell: "pwsh" });
    updateSession("terminal-1", { currentDirectory: "C:\\work\\proj\\src" });

    expect(getSession("terminal-1")?.shell).toBe("pwsh");
  });

  test("reports no shell before initialization records one", () => {
    const store = createTerminalStore();

    expect(store.getState().actions.getSession("terminal-1")?.shell).toBeUndefined();
  });
});
