import { afterEach, expect, spyOn, test } from "bun:test";
import * as tauriPath from "@tauri-apps/api/path";
import * as coreClient from "@/core/lithe-core-client";
import { useProjectStore } from "@/features/window/stores/project.store";
import { recordLocalHistoryFile, relocateLocalHistory } from "./local-history-api";

type Call = { command: string; payload: Record<string, unknown> };
const calls: Call[] = [];
const spies: Array<{ mockRestore: () => void }> = [];

// Core's answer for `history.planEvent("save")`, as pinned by shared/fixtures/history/event-plan-v1.json.
const savePlan = {
  snapshots: [
    { source: "beforeChange", reason: "saved" },
    { source: "afterChange", reason: "saved" },
  ],
};

function installCore(plan: unknown) {
  calls.length = 0;
  const previousRoot = useProjectStore.getState().rootFolderPath;
  useProjectStore.setState({ rootFolderPath: "C:/workspace" });
  spies.push({ mockRestore: () => useProjectStore.setState({ rootFolderPath: previousRoot }) });
  spies.push(spyOn(tauriPath, "appDataDir").mockResolvedValue("C:/appdata"));
  spies.push(spyOn(tauriPath, "join").mockImplementation((async (...parts: string[]) => parts.join("/")) as typeof tauriPath.join));
  spies.push(
    spyOn(coreClient, "executeCore").mockImplementation((async (request: { command: string; payload: Record<string, unknown> }) => {
      calls.push({ command: request.command, payload: request.payload });
      if (request.command === "history.planEvent") return { ok: true, data: plan };
      if (request.command === "history.record") {
        return { ok: true, data: { id: "entry", timestamp: 1, relativePath: "a.txt", reason: request.payload.reason, contentPath: "p", byteCount: 1 } };
      }
      return { ok: true, data: { relocated: true } };
    }) as unknown as typeof coreClient.executeCore),
  );
}

afterEach(() => {
  while (spies.length) spies.pop()!.mockRestore();
});

test("a save records the replaced text before the write and the saved text after it", async () => {
  installCore(savePlan);
  await recordLocalHistoryFile("C:/workspace/a.txt", "save", "beforeChange");
  await recordLocalHistoryFile("C:/workspace/a.txt", "save", "afterChange");
  expect(calls.map((call) => call.command)).toEqual([
    "history.planEvent", "history.record", "history.planEvent", "history.record",
  ]);
  expect(calls.filter((call) => call.command === "history.planEvent").map((call) => call.payload)).toEqual([
    { event: "save" }, { event: "save" },
  ]);
  expect(calls.filter((call) => call.command === "history.record").map((call) => call.payload.reason)).toEqual([
    "saved", "saved",
  ]);
});

test("a phase the event does not plan records nothing", async () => {
  installCore({ snapshots: [{ source: "beforeChange", reason: "restored" }] });
  expect(await recordLocalHistoryFile("C:/workspace/a.txt", "restore", "afterChange")).toBeNull();
  expect(calls.map((call) => call.command)).toEqual(["history.planEvent"]);
});

test("a rename moves retained history by workspace-relative paths", async () => {
  installCore(savePlan);
  await relocateLocalHistory("C:/workspace/src/a.txt", "C:/workspace/lib/a.txt");
  const relocate = calls.find((call) => call.command === "history.relocate")!;
  expect(relocate.payload).toMatchObject({ sourcePath: "src/a.txt", destinationPath: "lib/a.txt" });
});

test("paths outside the workspace have no history to move", async () => {
  installCore(savePlan);
  await relocateLocalHistory("C:/workspace/a.txt", "D:/elsewhere/a.txt");
  expect(calls).toEqual([]);
});
