import { expect, spyOn, test } from "bun:test";
import * as native from "@/platform/tauri-core";
import { planDuplicateName } from "./copy-names";

test("a planned name that exists becomes a fact and Core plans around it", async () => {
  const requests: unknown[] = [];
  // Core's answers for foo.txt, as pinned by shared/fixtures/workspace/file-copy-names-v1.json.
  const answers = ["foo copy.txt", "foo copy 2.txt"];
  const invoke = spyOn(native, "invoke").mockImplementation((async (_command: string, payload?: unknown) => {
    requests.push(JSON.parse(JSON.stringify(payload)));
    return { name: answers[requests.length - 1] };
  }) as typeof native.invoke);
  try {
    const name = await planDuplicateName({
      name: "foo.txt",
      isDirectory: false,
      exists: (candidate) => candidate === "foo copy.txt",
      caseInsensitive: true,
    });
    expect(name).toBe("foo copy 2.txt");
    expect(requests).toEqual([
      { name: "foo.txt", isDirectory: false, existing: [], caseInsensitive: true },
      { name: "foo.txt", isDirectory: false, existing: ["foo copy.txt"], caseInsensitive: true },
    ]);
  } finally {
    invoke.mockRestore();
  }
});

test("a destination that never frees up fails with the stable destination_exists code", async () => {
  let count = 0;
  const invoke = spyOn(native, "invoke").mockImplementation((async () => ({ name: `n${count++}` })) as typeof native.invoke);
  try {
    await expect(
      planDuplicateName({ name: "a", isDirectory: false, exists: () => true }),
    ).rejects.toThrow("destination_exists");
    expect(count).toBe(512);
  } finally {
    invoke.mockRestore();
  }
});
