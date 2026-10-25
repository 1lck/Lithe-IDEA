import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { readAgentStatistics, writeAgentStatistics } from "../../../platform/agent-statistics-storage";
import { emptySessionStatistics } from "../types/agent-session-statistics";

const original = Object.getOwnPropertyDescriptor(globalThis, "localStorage");
let values: Map<string, string>;
beforeEach(() => {
  values = new Map();
  Object.defineProperty(globalThis, "localStorage", { configurable: true, value: {
    getItem: (key: string) => values.get(key) ?? null,
    setItem: (key: string, value: string) => { values.set(key, value); },
  } });
});
afterEach(() => {
  if (original) Object.defineProperty(globalThis, "localStorage", original);
  else Reflect.deleteProperty(globalThis, "localStorage");
});
describe("Durable Agent statistics", () => {
  test("isolates workspace, Agent and session while normalizing Windows path spelling", () => {
    const record = { ...emptySessionStatistics(), turnCount: 2 };
    writeAgentStatistics("C:\\Workspace", "codex", "session", record);
    expect(readAgentStatistics("c:/workspace", "codex", "session")).toEqual(record);
    for (const identity of [["C:/other", "codex", "session"], ["C:/Workspace", "claude", "session"], ["C:/Workspace", "codex", "other"]]) {
      expect(readAgentStatistics(identity[0], identity[1], identity[2])).toBeNull();
    }
  });
  test("bounds retained records and rejects corrupt persisted counters", () => {
    for (let index = 0; index < 205; index++) writeAgentStatistics("C:/sample", "codex", String(index), { ...emptySessionStatistics(), turnCount: 1 });
    expect(readAgentStatistics("C:/sample", "codex", "0")).toBeNull();
    expect(readAgentStatistics("C:/sample", "codex", "204")?.turnCount).toBe(1);
    const key = [...values.keys()][0];
    const records = JSON.parse(values.get(key)!);
    expect(records).toHaveLength(200);
    records[199].statistics.calls.input = -1;
    values.set(key, JSON.stringify(records));
    expect(readAgentStatistics("C:/sample", "codex", "204")).toBeNull();
  });
});
