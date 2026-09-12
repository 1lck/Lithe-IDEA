import { create } from "zustand";
import { observeGitExecution } from "@/platform/git-execution-events";
import { GitExecutionJournal, type GitConsoleRecord } from "../services/git-execution-journal";

const journal = new GitExecutionJournal();
export const useGitConsoleStore = create<{ records: GitConsoleRecord[]; active: Map<string, string> }>(() => ({ records: [], active: new Map() }));
let timer: ReturnType<typeof setTimeout> | undefined;
function flush() {
  if (timer !== undefined) clearTimeout(timer);
  timer = undefined;
  useGitConsoleStore.setState({ records: journal.records.map((record) => ({ ...record })), active: new Map(journal.active) });
}
export function clearGitConsole(root: string) { journal.clear(root); flush(); }
// Owned by the application lifetime; no interval is left running while idle.
const unsubscribe = observeGitExecution((event) => {
  journal.receive(event);
  if (event.type === "requestFinished") flush();
  else if (timer === undefined) timer = setTimeout(flush, 100);
});
if (import.meta.hot) import.meta.hot.dispose(() => { unsubscribe(); if (timer !== undefined) clearTimeout(timer); });
