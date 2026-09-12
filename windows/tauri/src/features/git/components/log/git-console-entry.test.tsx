import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { LocaleProvider } from "@/i18n/locale-provider";
import { GitExecutionJournal } from "../../services/git-execution-journal";
import { GitConsoleEntry } from "./git-console-entry";

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
  expect(markup.indexOf("remote response")).toBeLessThan(markup.indexOf("updated reference"));
  expect(markup).toContain('class="text-destructive">remote response');
});
