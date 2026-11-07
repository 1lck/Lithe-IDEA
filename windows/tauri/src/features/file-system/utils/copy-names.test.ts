import { expect, spyOn, test } from "bun:test";
import * as native from "@/platform/tauri-core";
import { duplicateWithPlannedName } from "./copy-names";

/** Core's rule for foo.txt, as pinned by shared/fixtures/workspace/file-copy-names-v1.json. */
const coreAnswer = (existing: string[]) =>
  ["foo copy.txt", "foo copy 2.txt", "foo copy 3.txt"].find((name) => !existing.includes(name))!;

const installCore = (requests: unknown[]) =>
  spyOn(native, "invoke").mockImplementation((async (_command: string, payload?: unknown) => {
    const request = JSON.parse(JSON.stringify(payload)) as { existing: string[] };
    requests.push(request);
    return { name: coreAnswer(request.existing) };
  }) as typeof native.invoke);

test("names the provider lists but the in-memory tree lacks are avoided", async () => {
  const requests: unknown[] = [];
  const invoke = installCore(requests);
  try {
    const created: string[] = [];
    const { name } = await duplicateWithPlannedName({
      name: "foo.txt",
      isDirectory: false,
      listNames: async () => ["foo.txt", "foo copy.txt"],
      create: async (candidate) => { created.push(candidate); },
    });
    expect(name).toBe("foo copy 2.txt");
    expect(created).toEqual(["foo copy 2.txt"]);
    expect(requests).toEqual([
      { name: "foo.txt", isDirectory: false, existing: ["foo.txt", "foo copy.txt"], caseInsensitive: false },
    ]);
  } finally {
    invoke.mockRestore();
  }
});

test("destination_exists from the backend adds the name to the facts and plans again", async () => {
  const requests: unknown[] = [];
  const invoke = installCore(requests);
  try {
    const attempts: string[] = [];
    const { name } = await duplicateWithPlannedName({
      name: "foo.txt",
      isDirectory: false,
      listNames: async () => ["foo.txt"],
      create: async (candidate) => {
        attempts.push(candidate);
        if (candidate === "foo copy.txt") throw new Error("destination_exists: foo copy.txt");
      },
    });
    expect(attempts).toEqual(["foo copy.txt", "foo copy 2.txt"]);
    expect(name).toBe("foo copy 2.txt");
    expect((requests[1] as { existing: string[] }).existing).toEqual(["foo.txt", "foo copy.txt"]);
  } finally {
    invoke.mockRestore();
  }
});

test("other backend errors and an endless race are not retried forever", async () => {
  const invoke = spyOn(native, "invoke").mockImplementation((async () => ({ name: "x" })) as typeof native.invoke);
  try {
    await expect(duplicateWithPlannedName({
      name: "a", isDirectory: false, listNames: async () => [],
      create: async () => { throw new Error("permission denied"); },
    })).rejects.toThrow("permission denied");
  } finally {
    invoke.mockRestore();
  }
});
