import { invoke } from "@/platform/tauri-core";
import type { CommitAISettings, CommitDetection, CommitFileInput } from "../types/ai-commit";
import { getWorkingTreePathDiff } from "../api/git-diff-api";
import { collectCommitContext } from "./ai-commit-context";
import type { GitFile } from "../types/git.types";
export { commitSelectionKey } from "./ai-commit-context";
export const collectCommitFiles = (repo: string, files: GitFile[], signal: AbortSignal) =>
  collectCommitContext(repo, files, signal, getWorkingTreePathDiff);

type Translate = (key: string, values?: Record<string, string | number>) => string;
export function commitAIError(error: unknown, t: Translate): string {
  const code = error instanceof Error ? error.message : String(error);
  const http = /^AI_COMMIT_HTTP_(\d{3})$/.exec(code);
  if (http) return t("aiCommit.httpError", { status: http[1] });
  const key = `aiCommit.${code}`;
  const translated = t(key);
  return translated === key ? t("aiCommit.failed") : translated;
}

export const detectCommitConfigurations = () => invoke<CommitDetection>("ai_commit_detect");
export const commitKey = (id: string, action: "status" | "save" | "remove", value?: string) =>
  invoke<boolean>("ai_commit_key", { id, action, value });

export async function generateCommitMessage(
  settings: CommitAISettings,
  files: CommitFileInput[],
  signal: AbortSignal,
): Promise<string> {
  signal.throwIfAborted();
  const provider = settings.providers.find((p) => p.id === settings.activeProviderId);
  if (!provider) throw new Error("AI_COMMIT_INVALID_PROVIDER");
  const operationId = crypto.randomUUID();
  const cancel = () => {
    void invoke("ai_commit_cancel", { operationId }).catch(() => {
      console.warn("AI cancellation failed; the host request remains limited to 45 seconds.");
    });
  };
  signal.addEventListener("abort", cancel, { once: true });
  try {
    const { message } = await invoke<{ message: string }>("ai_commit_generate", {
      operationId,
      provider,
      options: settings,
      files,
    });
    signal.throwIfAborted();
    return message;
  } finally {
    signal.removeEventListener("abort", cancel);
  }
}
