import { describe, expect, test } from "bun:test";
import { createTerminalShellsStore } from "./shells.store";
import type { Shell } from "../types/terminal.types";

const bash: Shell = { id: "bash", name: "Git Bash" };
const nu: Shell = { id: "nu", name: "Nushell" };

describe("installed shell discovery", () => {
  test("caches discovery and refreshes explicitly without clearing the previous list", async () => {
    let shells = [bash];
    let calls = 0;
    const store = createTerminalShellsStore(async () => {
      calls++;
      return shells;
    });
    await store.getState().actions.loadShells();
    shells = [bash, nu];
    await store.getState().actions.loadShells();
    expect(calls).toBe(1);
    expect(store.getState().shells).toEqual([bash]);
    await store.getState().actions.loadShells({ force: true });
    expect(calls).toBe(2);
    expect(store.getState().shells).toEqual([bash, nu]);
  });

  test("coalesces concurrent refreshes and retains choices after a discovery failure", async () => {
    let reject: (error: Error) => void = () => {};
    let calls = 0;
    const store = createTerminalShellsStore(() => {
      calls++;
      return new Promise<Shell[]>((_, fail) => {
        reject = fail;
      });
    });
    store.setState({ shells: [bash], hasLoaded: true });
    const pending = store.getState().actions.loadShells({ force: true });
    try {
      await store.getState().actions.loadShells({ force: true });
      expect(calls).toBe(1);
      expect(store.getState().shells).toEqual([bash]);
    } finally {
      reject(new Error("discovery unavailable"));
      await pending;
    }
    expect(store.getState().shells).toEqual([bash]);
    expect(store.getState().hasLoaded).toBe(true);
    expect(store.getState().isLoading).toBe(false);
    expect(store.getState().error).toContain("discovery unavailable");
  });
});
