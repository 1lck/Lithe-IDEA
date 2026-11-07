import { invoke } from "@/platform/tauri-core";
import type { CommitAISettings } from "@/features/git/types/ai-commit";
import type { GitDiff } from "@/features/git/types/git.types";

/**
 * AI pull request descriptions share the AI commit provider, evidence policy and
 * request planning in Rust Core (`ai.pullRequest.plan` / `ai.pullRequest.decode`).
 * This module only converts the local branch comparison into Core facts; the
 * native host resolves the credential and performs HTTP.
 */
export interface PullRequestDescriptionDraft {
  title: string;
  description: string;
}

export interface PullRequestComparisonFile {
  path: string;
  changeKind: "added" | "deleted" | "renamed" | "modified";
  diff: string;
}

function changeKind(diff: GitDiff): PullRequestComparisonFile["changeKind"] {
  if (diff.is_new) return "added";
  if (diff.is_deleted) return "deleted";
  if (diff.is_renamed) return "renamed";
  return "modified";
}

function patchText(diff: GitDiff): string {
  if (diff.is_binary || diff.is_image) return "";
  if (diff.raw_patch) return diff.raw_patch;
  return diff.lines
    .map((line) => {
      switch (line.line_type) {
        case "added":
          return `+${line.content}`;
        case "removed":
          return `-${line.content}`;
        case "context":
          return ` ${line.content}`;
        default:
          return line.content;
      }
    })
    .join("\n");
}

/** Every changed file is reported, including binary ones, so Core applies its sensitive-path policy. */
export function comparisonFiles(diffs: readonly GitDiff[]): PullRequestComparisonFile[] {
  return diffs.map((diff) => ({
    path: diff.file_path,
    changeKind: changeKind(diff),
    diff: patchText(diff),
  }));
}

export async function generatePullRequestDescription(
  settings: CommitAISettings,
  comparison: {
    repository: string;
    base: string;
    head: string;
    files: PullRequestComparisonFile[];
  },
  signal: AbortSignal,
): Promise<PullRequestDescriptionDraft> {
  signal.throwIfAborted();
  const provider = settings.providers.find((item) => item.id === settings.activeProviderId);
  if (!provider) throw new Error("AI_COMMIT_INVALID_PROVIDER");
  const operationId = crypto.randomUUID();
  const cancel = () => {
    void invoke("ai_commit_cancel", { operationId }).catch(() => {
      console.warn("AI cancellation failed; the host request remains limited to 45 seconds.");
    });
  };
  signal.addEventListener("abort", cancel, { once: true });
  try {
    const draft = await invoke<PullRequestDescriptionDraft>("ai_commit_pull_request", {
      operationId,
      provider,
      options: {
        language: settings.language,
        format: "standard",
        customTemplate: "",
        maximumDiffCharacters: settings.maximumDiffCharacters,
        reasoningEffort: settings.reasoningEffort,
      },
      comparison: { ...comparison, commitMessages: [] },
    });
    signal.throwIfAborted();
    return draft;
  } finally {
    signal.removeEventListener("abort", cancel);
  }
}
