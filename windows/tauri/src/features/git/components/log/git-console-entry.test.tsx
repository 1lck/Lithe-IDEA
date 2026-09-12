import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { LocaleProvider } from "@/i18n/locale-provider";
import { GitExecutionJournal } from "../../services/git-execution-journal";
import { GitConsoleEntry } from "./git-console-entry";
import fixture from "../../../../../../../shared/fixtures/git/console-command-v1.json";

test("console defaults to timestamp, command and ordered output with metadata folded", () => {
  const journal = new GitExecutionJournal(() => new Date(2026, 0, 1, 14, 9, 40, 880).getTime());
  journal.receive({ operationId: "fetch", type: "started", invocationId: 1,
    workingDirectory: "C:/repo", arguments: ["fetch", "origin", "--progress", "--prune"],
    executable: "C:/Git/bin/git.exe", temporaryConfig: [["core.quotepath", "false"]] });
  journal.receive({ operationId: "fetch", type: "output", invocationId: 1, stream: "stderr", text: "remote response" });
  journal.receive({ operationId: "fetch", type: "output", invocationId: 1, stream: "stdout", text: "updated reference" });
  journal.receive({ operationId: "fetch", type: "finished", invocationId: 1, exitCode: 0, durationMilliseconds: 42 });
  const markup = renderToStaticMarkup(<LocaleProvider language="zh-CN"><GitConsoleEntry record={journal.records[0]} /></LocaleProvider>);
  expect(markup).toContain("14:09:40.880: [C:/repo] git");
  expect(markup).toContain("fetch origin --progress --prune");
  expect(markup).toContain("-c …");
  expect(markup).toContain('aria-expanded="false"');
  expect(markup).not.toContain("core.quotepath");
  expect(markup).not.toContain("C:/Git/bin/git.exe");
  expect(markup).not.toContain("42 ms");
  expect(markup).not.toContain("⋯");
  expect(markup.indexOf("remote response")).toBeLessThan(markup.indexOf("updated reference"));
  expect(markup).toContain('class="text-destructive">remote response');
});

test("actual Fetch global flags stay inside the single options disclosure", () => {
  const sample = fixture.cases[0];
  const journal = new GitExecutionJournal(() => 0);
  journal.receive({ operationId: "fetch", type: "started", invocationId: 1,
    workingDirectory: "C:/repo", ...sample });
  const record = journal.records[0];
  expect(record.arguments).toEqual(sample.arguments);
  expect(record.globalArguments).toEqual(sample.globalArguments);
  const markup = renderToStaticMarkup(<LocaleProvider language="zh-CN"><GitConsoleEntry record={record} /></LocaleProvider>);
  expect(markup).toContain("fetch --progress --prune -- origin");
  expect(markup.split("-c …")).toHaveLength(2);
  expect(markup).not.toContain("color.ui=false");
  expect(markup).not.toContain("core.quotepath=false");
  expect(markup).not.toContain("--no-pager");
  expect(markup).not.toContain("⋯");
});
