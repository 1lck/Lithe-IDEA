import { afterEach, beforeEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { installHappyDom } from "@/test-utils/happy-dom";
import { LocaleProvider } from "@/i18n/locale-provider";
import { GitConsoleEntry } from "./git-console-entry";
import { consolePresentationRequest, type ConsolePresentation, type ConsoleSearchHit } from "../../services/git-console-presentation";
import { GitExecutionJournal, type GitConsoleRecord } from "../../services/git-execution-journal";
import fixture from "../../../../../../../shared/fixtures/git/console-presentation-v1.json";

let restoreDom: () => void;
let root: Root;
let container: HTMLDivElement;
const actGlobal = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
let previousAct: boolean | undefined;
beforeEach(() => {
  restoreDom = installHappyDom();
  previousAct = actGlobal.IS_REACT_ACT_ENVIRONMENT;
  actGlobal.IS_REACT_ACT_ENVIRONMENT = true;
  container = document.createElement("div");
  document.body.append(container);
  root = createRoot(container);
});
afterEach(async () => {
  await act(async () => root.unmount());
  container.remove();
  restoreDom();
  actGlobal.IS_REACT_ACT_ENVIRONMENT = previousAct;
});

function recordFromSample(index: number): GitConsoleRecord {
  const raw = fixture.cases[index]!.input.records[0]! as unknown as GitConsoleRecord;
  return { ...raw, timestamp: 0, operationId: "fixture", action: "Git", truncated: raw.truncated ?? false,
    state: raw.state as GitConsoleRecord["state"], source: raw.source as GitConsoleRecord["source"],
    output: raw.lines.map((line) => line.text + "\n").join(""),
    lines: raw.lines as GitConsoleRecord["lines"],
  };
}
async function render(record: GitConsoleRecord, presentation: ConsolePresentation, selectedHit?: ConsoleSearchHit) {
  await act(async () => root.render(<LocaleProvider language="zh-CN">
    <GitConsoleEntry record={record} presentation={presentation.entries[0]} selectedHit={selectedHit} />
  </LocaleProvider>));
}

test("progress expands in place, stays expanded on refresh and retains original data", async () => {
  const record = recordFromSample(15);
  const presentation = fixture.cases[15]!.presentation as ConsolePresentation;
  const fragment = presentation.entries[0]!.output.find((value) => value.kind !== "text")!;
  const hidden = record.lines[fragment.start + 1]!.text;
  await render(record, presentation);
  expect(container.textContent).not.toContain(hidden);
  const disclosure = [...container.querySelectorAll<HTMLButtonElement>("button")].find((button) => button.textContent?.includes("Compressing objects"))!;
  expect(disclosure.getAttribute("aria-expanded")).toBe("false");
  await act(async () => disclosure.click());
  expect(container.textContent).toContain(hidden);
  await render({ ...record, durationMilliseconds: 25 }, structuredClone(presentation));
  expect(container.textContent).toContain(hidden);
  expect(consolePresentationRequest([record], "").records[0]!.lines).toEqual(record.lines);
  expect(record.output).toContain(hidden);
  expect(record.output).not.toContain("展开中间");
});

test("search opens the hidden output range and targets the retained original line", async () => {
  const record = recordFromSample(15);
  const presentation = fixture.cases[15]!.presentation as ConsolePresentation;
  const hit = presentation.matches[0]!;
  await render(record, presentation);
  expect(container.querySelector(`[data-console-anchor="${record.id}:line-${hit.lineIndex}"]`)).toBeNull();
  await render(record, presentation, hit);
  const line = container.querySelector(`[data-console-anchor="${record.id}:line-${hit.lineIndex}"]`);
  expect(line?.textContent).toBe(record.lines[hit.lineIndex!]!.text);
  expect(line?.className).toContain("bg-warning");
});

test("shared fixtures retain every original line and keep executions independent", () => {
  for (const sample of fixture.cases) {
    const presentation = sample.presentation as ConsolePresentation;
    expect(presentation.groups.map((group) => group.recordIds)).toEqual(sample.input.records.map((record) => [record.id]));
    for (let index = 0; index < presentation.entries.length; index += 1) {
      const raw = sample.input.records[index]!;
      const entry = presentation.entries[index]!;
      expect(entry.output.flatMap((fragment) => raw.lines.slice(fragment.start, fragment.end))).toEqual(raw.lines);
    }
  }
});

test("optional query exit and transfer summaries preserve their execution identity", () => {
  const journal = new GitExecutionJournal(() => 0);
  journal.receive({ operationId: "fetch", invocationId: 1, type: "started", arguments: ["fetch", "origin"], source: "user" });
  journal.receive({ operationId: "fetch", invocationId: 1, type: "finished", exitCode: 0 });
  journal.receive({ operationId: "fetch", invocationId: 2, type: "started", arguments: ["config", "--get", "optional"], source: "background" });
  journal.receive({ operationId: "fetch", invocationId: 2, type: "finished", exitCode: 1, expectedExit: true });
  journal.receive({ operationId: "fetch", invocationId: 1, type: "remoteResult", remote: "origin", succeeded: true });
  expect(journal.records[0]!.remoteResult?.remote).toBe("origin");
  expect(journal.records[1]!.remoteResult).toBeUndefined();
  const request = consolePresentationRequest(journal.records, "");
  expect(request.records[1]!.expectedExit).toBe(true);
  expect(request.records[1]!.exitCode).toBe(1);
  expect(request.records[1]!.source).toBe("background");
});

test("silent completion and running notices are visible without changing copied output", async () => {
  const notices = [
    ["running command waits for output", "正在执行 Git，等待输出。"],
    ["successful command with no output", "执行成功，没有输出。"],
    ["fetch without reference changes", "获取完成，没有引用变化。"],
  ];
  for (const [name, message] of notices) {
    const index = fixture.cases.findIndex((sample) => sample.name === name);
    expect(index).toBeGreaterThanOrEqual(0);
    const record = recordFromSample(index);
    await render(record, fixture.cases[index]!.presentation as ConsolePresentation);
    expect(container.querySelector('[role="status"]')?.textContent).toBe(message);
    expect(record.output).toBe("");
    expect(consolePresentationRequest([record], "").records[0]!.lines).toEqual([]);
  }
});
