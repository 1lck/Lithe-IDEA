import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { create } from "zustand";
import { configureGitExecutionPreferences, observeGitExecution, type GitExecutionEvent } from "@/platform/git-execution-events";
import { GitExecutionJournal, type GitConsoleRecord } from "../services/git-execution-journal";
import { updateGitFetchProgress, type GitFetchProgress } from "../services/git-fetch-progress";

configureGitExecutionPreferences(() => {
  const settings = useSettingsStore.getState().settings;
  return { executable: settings.gitExecutable || null, useCredentialHelper: settings.gitUseCredentialHelper,
    detailedFetch: true, fetchDefaults: { remote: null, prune: settings.gitFetchPrune, submodules: settings.gitFetchSubmodules, tags: settings.gitFetchTags } };
});
const journal = new GitExecutionJournal();
let fetches: GitFetchProgress[] = [];
export const useGitConsoleStore = create<{ historyTruncated: boolean; records: GitConsoleRecord[]; active: Map<string, string>; authentication: GitExecutionEvent[]; fetches: GitFetchProgress[] }>(() => ({ historyTruncated: false, records: [], active: new Map(), authentication: [], fetches: [] }));
let timer: ReturnType<typeof setTimeout> | undefined;
function flush() {
  if (timer !== undefined) clearTimeout(timer);
  timer = undefined;
  useGitConsoleStore.setState({ historyTruncated: journal.historyTruncated, records: journal.records.map((record) => ({ ...record, lines: [...record.lines] })), active: new Map(journal.active), authentication: [...journal.authentication], fetches });
}
export function dismissGitAuthentication(requestID: string) { journal.authentication = journal.authentication.filter((request) => request.requestId !== requestID); flush(); }
export function clearGitConsole(root?: string) { journal.clear(root); flush(); }
// Owned by the application lifetime; no interval is left running while idle.
const unsubscribe = observeGitExecution((event) => {
  journal.receive(event);
  fetches = updateGitFetchProgress(fetches, event);
  if (event.type === "requestFinished" || event.type === "authentication" || (event.type === "requestStarted" && event.action === "git_fetch")) flush();
  else if (timer === undefined) timer = setTimeout(flush, 100);
});
if (import.meta.hot) import.meta.hot.dispose(() => { unsubscribe(); if (timer !== undefined) clearTimeout(timer); });
