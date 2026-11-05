import { afterEach, beforeEach, describe, expect, mock, spyOn, test } from "bun:test";
import * as native from "@/platform/tauri-core";
import fixture from "../../../../../../shared/fixtures/terminal/link-target-v1.json";

const existing = new Set<string>();
mock.module("@tauri-apps/plugin-fs", () => ({
  stat: async (path: string) => {
    if (!existing.has(path)) throw new Error("missing");
    return { isFile: true };
  },
}));
mock.module("@tauri-apps/api/path", () => ({ homeDir: async () => "/Users/me" }));

const { findTerminalFileLinks } = await import("./terminal-file-links");

type FixtureCase = (typeof fixture.cases)[number];
const byName = (name: string) => fixture.cases.find((item) => item.name === name) as FixtureCase;

let invoke: ReturnType<typeof spyOn>;
beforeEach(() => {
  existing.clear();
});
afterEach(() => invoke?.mockRestore());

/** Answers `terminal.parseLinkTarget` with the Core-verified fixture result for the same texts. */
function answerFromFixture(item: FixtureCase) {
  invoke = spyOn(native, "invoke").mockImplementation((async (command: string, payload: unknown) => {
    expect(command).toBe("terminal.parseLinkTarget");
    expect((payload as { texts: string[] }).texts).toEqual(item.request.texts);
    expect((payload as { baseDirectory?: string }).baseDirectory).toBe(item.request.baseDirectory);
    return { targets: item.expected };
  }) as typeof native.invoke);
}

describe("terminal file links", () => {
  test("keeps hit regions on the trimmed token and opens only existing files", async () => {
    answerFromFixture(byName("relative-path-with-line-and-column"));
    existing.add("/work/project/Sources/App.swift");
    const line = "(Sources/App.swift:12:4), src/lib.rs:7 ./a/../b.txt.";

    const links = await findTerminalFileLinks(line, "/work/project");

    expect(links).toEqual([
      {
        text: "Sources/App.swift:12:4",
        path: "/work/project/Sources/App.swift",
        line: 12,
        column: 4,
        startIndex: 1,
        endIndex: 23,
      },
    ]);
  });

  test("does not depend on file extensions and ignores bare words", async () => {
    answerFromFixture(byName("extension-is-never-inspected"));
    for (const path of ["Makefile", "build/output", "LICENSE", "notes.zzz"]) {
      existing.add(`/work/project/${path}`);
    }

    const links = await findTerminalFileLinks(
      "Makefile build/output LICENSE:3 notes.zzz",
      "/work/project",
    );

    expect(links.map((link) => [link.text, link.path, link.line])).toEqual([
      ["build/output", "/work/project/build/output", undefined],
      ["LICENSE:3", "/work/project/LICENSE", 3],
    ]);
  });

  test("provider files that cannot be checked need an explicit line", async () => {
    answerFromFixture(byName("provider-workspace-keeps-paths-inside-the-provider"));

    const links = await findTerminalFileLinks("src/a.rs:3 /etc/hosts wsl://Ubuntu/home/me/b.rs:1 ../c.rs", "remote://conn1/home/me/app");

    expect(links.map((link) => link.path)).toEqual([
      "remote://conn1/home/me/app/src/a.rs",
      "wsl://Ubuntu/home/me/b.rs",
    ]);
  });
});
