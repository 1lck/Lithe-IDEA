import { afterEach, expect, test } from "bun:test";
import {
  applyWorkDoneProgress,
  clearLanguageServerProgress,
  finishLanguageServerImport,
  getImportProgress,
  JAVA_IMPORT_PROGRESS_MESSAGE,
  languageServerProgressStore,
  recordLanguageServerProgress,
  WORK_DONE_PROGRESS_MESSAGE,
} from "./language-server-progress.store";

const SESSION = { id: "session-1", workspacePath: "C:\\work\\repo", languageId: "java" };

afterEach(() => languageServerProgressStore.setState({ sessions: {} }));

function progress(token: string | number, value: Record<string, unknown>) {
  return JSON.stringify({ token, value });
}

test("the Java import snapshot is readable by root until the service is ready", () => {
  recordLanguageServerProgress(
    SESSION,
    JAVA_IMPORT_PROGRESS_MESSAGE,
    JSON.stringify({
      stage: "serviceReady",
      phase: "Importing Maven project(s)",
      progressPercent: 42.4,
      currentProject: "module-a",
      downloadArtifact: null,
    }),
  );
  // Roots compare without case or separator differences, as on Windows.
  expect(getImportProgress("c:/work/repo/", "java")).toEqual({
    percent: 42,
    phase: "Importing Maven project(s)",
    currentProject: "module-a",
    downloadArtifact: undefined,
    downloadedBytes: undefined,
    totalBytes: undefined,
  });
  expect(getImportProgress("C:/work/repo", "typescript")).toBeUndefined();

  finishLanguageServerImport(SESSION.id);
  expect(getImportProgress("C:/work/repo", "java")).toBeUndefined();
});

test("work-done progress tracks tasks from begin to end", () => {
  let tasks = applyWorkDoneProgress([], progress("build", { kind: "begin", title: "Building" }));
  expect(tasks).toEqual([{ token: "build", title: "Building", message: undefined, percent: undefined }]);

  tasks = applyWorkDoneProgress(tasks, progress("build", { kind: "report", message: "module-a", percentage: 50 }));
  tasks = applyWorkDoneProgress(tasks, progress(7, { kind: "report", percentage: 10 }));
  expect(tasks).toEqual([
    { token: "build", title: "Building", message: "module-a", percent: 50 },
    // A report whose begin was not seen still describes running work.
    { token: "7", title: undefined, message: undefined, percent: 10 },
  ]);

  // A report without a percentage keeps the last known one.
  tasks = applyWorkDoneProgress(tasks, progress("build", { kind: "report", message: "module-b" }));
  expect(tasks[0]).toEqual({ token: "build", title: "Building", message: "module-b", percent: 50 });

  tasks = applyWorkDoneProgress(tasks, progress("build", { kind: "end" }));
  expect(tasks.map((task) => task.token)).toEqual(["7"]);
});

test("malformed or unrelated progress leaves tasks untouched", () => {
  const tasks = applyWorkDoneProgress([], progress("a", { kind: "begin", title: "A" }));
  for (const detail of [undefined, "", "not json", "[]", JSON.stringify({ token: "a" }), progress("a", { kind: "other" })]) {
    expect(applyWorkDoneProgress(tasks, detail)).toBe(tasks);
  }
  expect(applyWorkDoneProgress(tasks, progress("missing", { kind: "end" }))).toBe(tasks);
});

test("a stopped session drops its tasks", () => {
  recordLanguageServerProgress(SESSION, WORK_DONE_PROGRESS_MESSAGE, progress("build", { kind: "begin", title: "Building" }));
  expect(languageServerProgressStore.getState().sessions[SESSION.id]?.tasks).toHaveLength(1);
  clearLanguageServerProgress(SESSION.id);
  expect(languageServerProgressStore.getState().sessions[SESSION.id]).toBeUndefined();
});

test("other log messages are ignored", () => {
  recordLanguageServerProgress(SESSION, "Language-server log", progress("build", { kind: "begin" }));
  expect(languageServerProgressStore.getState().sessions).toEqual({});
});
