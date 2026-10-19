import { expect, test } from "bun:test";
import { historyWorkspaceIdentity, toLocalEntry } from "./history-metadata";

test("history isolates equal relative paths in different workspaces while normalizing Windows roots", async () => {
  const left = await historyWorkspaceIdentity("C:/example/project/");
  expect(await historyWorkspaceIdentity("c:\\EXAMPLE\\project")).toBe(left);
  expect(await historyWorkspaceIdentity("D:/example/project")).not.toBe(left);
  expect(await historyWorkspaceIdentity("C:/example/project-copy")).not.toBe(left);
});

test("history translates Core epoch seconds to the UI millisecond clock", () => {
  const entry = toLocalEntry({
    id: "snapshot",
    timestamp: 1700000000,
    relativePath: "目录/a.txt",
    reason: "saved",
    contentPath: "snapshot.txt",
    byteCount: 12,
  });
  expect(new Date(entry.created_at).toISOString()).toBe("2023-11-14T22:13:20.000Z");
  expect(entry.file_name).toBe("a.txt");
});
