import {
  ArrowDownIcon as ArrowDown,
  ArrowUpIcon as ArrowUp,
  CheckIcon as Check,
  CaretDownIcon as ChevronDown,
  WarningCircleIcon as AlertCircle,
  SparkleIcon as Sparkles,
} from "@/ui/icons";
import type React from "react";
import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { toast } from "sonner";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import { ButtonGroup, ButtonGroupSeparator } from "@/ui/button-group";
import { Dropdown, type MenuItem } from "@/ui/dropdown";
import { SidebarComposerBody } from "@/ui/sidebar";
import Textarea from "@/ui/textarea";
import { cn } from "@/utils/cn";
import {
  InlineEditError,
  requestInlineEdit,
} from "@/features/editor/services/editor-inline-edit-service";
import { commitSelectedChanges, getGitLog } from "../api/git-commits-api";
import { getWorkingTreePathDiff } from "../api/git-diff-api";
import { showGitPushDialog } from "../services/git-push-dialog-service";
import { useGitBlameStore } from "../stores/git-blame.store";
import { useGitStore } from "../stores/git.store";
import type { GitDiff, GitFile } from "../types/git.types";
import { resolveGitFileMutationPaths } from "../utils/git-status-selection";

interface GitCommitPanelProps {
  selectedFiles: GitFile[];
  commitMessage: string;
  onCommitMessageChange: (message: string) => void;
  currentBranch?: string;
  repoPath?: string;
  ahead?: number;
  behind?: number;
  onCommitSuccess?: () => void;
  onPull?: () => Promise<unknown> | void;
  isPulling?: boolean;
  focusRequest?: number;
}

const MAX_SELECTED_FILES_FOR_AI_CONTEXT = 120;
const MAX_RECENT_COMMITS_FOR_AI_CONTEXT = 24;
const MAX_DIFF_FILES_FOR_AI_CONTEXT = 10;
const MAX_DIFF_LINES_PER_FILE_FOR_AI_CONTEXT = 80;
const MAX_COMMIT_AI_CONTEXT_CHARS = 11_000;
const COMMIT_TEXTAREA_MIN_HEIGHT = 64;
const COMMIT_TEXTAREA_MAX_HEIGHT = 128;

type CommitMessageMode = "title" | "body";

const getRepoLabel = (repoPath: string): string => {
  const normalized = repoPath.replace(/\\/g, "/").replace(/\/$/, "");
  return normalized.split("/").pop() || "repository";
};

const countDiffLines = (diff: GitDiff | null) => {
  if (!diff) return { additions: 0, deletions: 0 };

  return diff.lines.reduce(
    (totals, line) => {
      if (line.line_type === "added") totals.additions += 1;
      if (line.line_type === "removed") totals.deletions += 1;
      return totals;
    },
    { additions: 0, deletions: 0 },
  );
};

const formatDiffExcerpt = (file: GitFile, diff: GitDiff | null): string => {
  if (!diff) return `### ${file.path}\n(no text diff available)`;
  if (diff.is_binary || diff.is_image) return `### ${file.path}\n(binary or image change)`;

  const changedLines: string[] = [];
  let changedLineCount = 0;

  for (const line of diff.lines) {
    if (line.line_type !== "added" && line.line_type !== "removed") continue;

    changedLineCount++;
    if (changedLines.length < MAX_DIFF_LINES_PER_FILE_FOR_AI_CONTEXT) {
      changedLines.push(`${line.line_type === "added" ? "+" : "-"}${line.content}`);
    }
  }

  const omittedCount = Math.max(changedLineCount - MAX_DIFF_LINES_PER_FILE_FOR_AI_CONTEXT, 0);

  return [
    `### ${file.path}`,
    changedLines.join("\n") || "(metadata-only change)",
    omittedCount > 0 ? `... ${omittedCount} more changed lines omitted` : "",
  ]
    .filter(Boolean)
    .join("\n");
};

const truncateContext = (context: string): string => {
  if (context.length <= MAX_COMMIT_AI_CONTEXT_CHARS) return context;
  return `${context.slice(0, MAX_COMMIT_AI_CONTEXT_CHARS)}\n\n[context truncated]`;
};

async function buildCommitMessageContext({
  repoPath,
  currentBranch,
  selectedFiles,
  existingDraftHint,
}: {
  repoPath: string;
  currentBranch?: string;
  selectedFiles: GitFile[];
  existingDraftHint: string;
}): Promise<string> {
  const selectedFilesForContext = selectedFiles.slice(0, MAX_SELECTED_FILES_FOR_AI_CONTEXT);
  const diffFilesForContext = selectedFiles.slice(0, MAX_DIFF_FILES_FOR_AI_CONTEXT);
  const [recentCommits, selectedDiffs] = await Promise.all([
    getGitLog(repoPath, MAX_RECENT_COMMITS_FOR_AI_CONTEXT),
    Promise.all(
      diffFilesForContext.map((file) =>
        getWorkingTreePathDiff(
          repoPath,
          file.path,
          file.status === "untracked",
          file.originalPath,
        ),
      ),
    ),
  ]);
  const overflowCount = Math.max(selectedFiles.length - selectedFilesForContext.length, 0);
  const diffOverflowCount = Math.max(selectedFiles.length - diffFilesForContext.length, 0);
  const totals = selectedDiffs.reduce(
    (sum, diff) => {
      const counts = countDiffLines(diff);
      return {
        additions: sum.additions + counts.additions,
        deletions: sum.deletions + counts.deletions,
      };
    },
    { additions: 0, deletions: 0 },
  );

  const recentCommitLines = recentCommits
    .map((commit) => commit.message.trim())
    .filter(Boolean)
    .slice(0, MAX_RECENT_COMMITS_FOR_AI_CONTEXT)
    .map((message) => `- ${message}`)
    .join("\n");
  const selectedLines = selectedFilesForContext
    .map((file) => `- ${file.status}: ${file.path}`)
    .join("\n");
  const diffExcerpt = diffFilesForContext
    .map((file, index) => formatDiffExcerpt(file, selectedDiffs[index]))
    .join("\n\n");

  return truncateContext(
    [
      `Repository: ${getRepoLabel(repoPath)}`,
      `Branch: ${currentBranch || "unknown"}`,
      "",
      "Recent commit subjects for style:",
      recentCommitLines || "- none",
      "",
      `Selected files (${selectedFiles.length}):`,
      selectedLines || "- none",
      overflowCount > 0 ? `- ...and ${overflowCount} more selected files` : "",
      "",
      `Selected diff summary for sampled files: +${totals.additions} -${totals.deletions}`,
      diffOverflowCount > 0
        ? `Diff excerpts include ${diffFilesForContext.length} of ${selectedFiles.length} selected files.`
        : "",
      diffExcerpt ? `\nSelected patch excerpts:\n${diffExcerpt}` : "",
      existingDraftHint ? `\nCurrent draft:\n${existingDraftHint}` : "",
    ]
      .filter(Boolean)
      .join("\n"),
  );
}

function normalizeGeneratedCommitMessage(message: string, mode: CommitMessageMode): string {
  const trimmed = message
    .replace(/^```[a-zA-Z0-9_-]*\n?/, "")
    .replace(/\n?```\s*$/, "")
    .trim();
  if (mode === "body") return trimmed;

  return (
    trimmed
      .split(/\r?\n/)
      .map((line) => line.trim())
      .find(Boolean) || ""
  );
}

const GitCommitPanel = ({
  selectedFiles,
  commitMessage,
  onCommitMessageChange,
  currentBranch,
  repoPath,
  ahead = 0,
  behind = 0,
  onCommitSuccess,
  onPull,
  isPulling = false,
  focusRequest = 0,
}: GitCommitPanelProps) => {
  const { t } = useTranslation();
  const aiAutocompleteProvider = useSettingsStore((state) => state.settings.aiAutocompleteProvider);
  const aiAutocompleteModelId = useSettingsStore((state) =>
    state.settings.aiAutocompleteProvider === "custom"
      ? state.settings.aiAutocompleteCustomModelId
      : state.settings.aiAutocompleteModelId,
  );
  const [isCommitting, setIsCommitting] = useState(false);
  const [isGenerating, setIsGenerating] = useState(false);
  const [commitMessageMode, setCommitMessageMode] = useState<CommitMessageMode>("title");
  const [isGenerateModeMenuOpen, setIsGenerateModeMenuOpen] = useState(false);
  const [isCommitActionMenuOpen, setIsCommitActionMenuOpen] = useState(false);
  const [remoteAction, setRemoteAction] = useState<"push" | null>(null);
  const [error, setError] = useState<string | null>(null);
  const generateMenuAnchorRef = useRef<HTMLDivElement>(null);
  const commitMenuAnchorRef = useRef<HTMLDivElement>(null);
  const commitTextareaRef = useRef<HTMLTextAreaElement>(null);
  const selectedFilesCount = selectedFiles.length;
  const operationState = useGitStore((state) => state.operationState);

  useEffect(() => {
    if (focusRequest <= 0) return;
    globalThis.requestAnimationFrame?.(() => commitTextareaRef.current?.focus());
  }, [focusRequest]);

  useLayoutEffect(() => {
    const textarea = commitTextareaRef.current;
    if (!textarea) return;

    textarea.style.height = "auto";
    const nextHeight = Math.min(
      COMMIT_TEXTAREA_MAX_HEIGHT,
      Math.max(COMMIT_TEXTAREA_MIN_HEIGHT, textarea.scrollHeight),
    );
    textarea.style.height = `${nextHeight}px`;
    textarea.style.overflowY =
      textarea.scrollHeight > COMMIT_TEXTAREA_MAX_HEIGHT ? "auto" : "hidden";
  }, [commitMessage]);

  const handleGenerateCommitMessage = async () => {
    if (!repoPath || selectedFilesCount === 0) return;
    setError(null);

    const existingDraftHint = commitMessage.trim();

    setIsGenerating(true);
    try {
      const selectedText = await buildCommitMessageContext({
        repoPath,
        currentBranch,
        selectedFiles,
        existingDraftHint,
      });
      const { editedText } = await requestInlineEdit({
        provider: aiAutocompleteProvider,
        customProviderScope: "autocomplete",
        model: aiAutocompleteModelId,
        beforeSelection: "",
        selectedText,
        afterSelection: "",
        instruction:
          commitMessageMode === "title"
            ? "Generate a concise Git commit subject from the selected changes. Return exactly one subject line and nothing else. Keep it under 72 characters when possible. Infer and match the repository's style from recent commit subjects. Do not force conventional commit format unless the recent commits clearly use it."
            : "Generate a Git commit message from the selected changes. Return a subject line and a short body only when the body adds useful context. Keep the subject under 72 characters when possible. Infer and match the repository's style from recent commit subjects. Do not force conventional commit format unless the recent commits clearly use it.",
        filePath: getRepoLabel(repoPath),
        languageId: "git-commit",
      });

      const message = normalizeGeneratedCommitMessage(editedText, commitMessageMode);
      if (!message) {
        setError(t("git.aiCommitEmptyMessage"));
        return;
      }

      onCommitMessageChange(message);
    } catch (generationError) {
      if (generationError instanceof InlineEditError) {
        setError(generationError.message);
      } else {
        setError(t("git.generateCommitMessageFailed"));
      }
    } finally {
      setIsGenerating(false);
    }
  };

  const handleCommit = async (pushAfterCommit = false) => {
    if (selectedFilesCount === 0) {
      setError(t("git.selectFilesToCommit"));
      return;
    }
    if (!repoPath || !commitMessage.trim()) return;

    // A conflicted merge/rebase must be resolved before the merge commit can
    // be finalized; guard here so Git's raw refusal never reaches the user.
    const activeOperation = useGitStore.getState().operationState;
    const conflictedPaths = activeOperation?.conflictedPaths ?? [];
    if (activeOperation && conflictedPaths.length > 0) {
      setError(t("git.resolveConflictsFirst", { paths: conflictedPaths.join(", ") }));
      return;
    }
    if (activeOperation) {
      setError(t("git.finishOperationBeforeCommit"));
      return;
    }

    setIsCommitting(true);
    setError(null);

    try {
      const warnings = await commitSelectedChanges(
        repoPath,
        commitMessage.trim(),
        resolveGitFileMutationPaths(selectedFiles),
      );
      useGitBlameStore.getState().actions.clearAllBlame();
      onCommitMessageChange("");
      for (const warning of warnings) {
        toast.warning(
          warning.code === "git_index_reconcile_failed"
            ? t("git.commitIndexReconcileFailed")
            : warning.message,
        );
      }
      if (pushAfterCommit) {
        setRemoteAction("push");
        try {
          await showGitPushDialog(repoPath);
        } catch (pushError) {
          setError(pushError instanceof Error ? pushError.message : t("git.pushFailed"));
        } finally {
          setRemoteAction(null);
        }
      }
      onCommitSuccess?.();
    } catch (error) {
      setError(
        error instanceof Error
          ? error.message
          : typeof error === "string"
            ? error
            : t("ai.unknownError"),
      );
    } finally {
      setIsCommitting(false);
    }
  };

  const handlePush = async () => {
    if (!repoPath) return;

    setRemoteAction("push");
    setError(null);

    try {
      await showGitPushDialog(repoPath);
    } finally {
      setRemoteAction(null);
    }
  };

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === "Enter" && (e.ctrlKey || e.metaKey)) {
      e.preventDefault();
      void handleCommit();
    }
  };

  const isCommitDisabled =
    selectedFilesCount === 0 ||
    !commitMessage.trim() ||
    Boolean(operationState) ||
    isCommitting ||
    isGenerating;
  const isGenerateDisabled = selectedFilesCount === 0 || isGenerating || isCommitting;
  const hasRemoteChanges = ahead > 0 || behind > 0;
  const isRemoteActionLoading = remoteAction !== null;
  const composerButtonClassName =
    "h-6 rounded-md border-transparent bg-transparent px-1.5 ui-text-sm leading-none text-subtle-foreground shadow-none hover:bg-accent/80 hover:text-foreground focus-visible:ring-1 focus-visible:ring-border-strong/35 [&_svg]:size-3";
  const generateModeItems: MenuItem[] = [
    {
      id: "title",
      label: t("git.commitMessageTitleOnly"),
      icon: commitMessageMode === "title" ? <Check /> : undefined,
      onClick: () => setCommitMessageMode("title"),
    },
    {
      id: "body",
      label: t("git.commitMessageTitleAndBody"),
      icon: commitMessageMode === "body" ? <Check /> : undefined,
      onClick: () => setCommitMessageMode("body"),
    },
  ];
  const commitActionItems: MenuItem[] = [
    {
      id: "commit-and-push",
      label: t("git.commitAndPush"),
      icon: <ArrowUp />,
      disabled: isCommitDisabled || isRemoteActionLoading || isPulling,
      onClick: () => {
        setIsCommitActionMenuOpen(false);
        void handleCommit(true);
      },
    },
  ];

  return (
    <>
      <SidebarComposerBody>
        {error && (
          <div
            className={cn(
              "mx-2 mt-2 flex items-center gap-2 rounded-md border border-destructive/30",
              "bg-destructive/20 px-2 py-1 ui-text-sm text-destructive",
            )}
          >
            <AlertCircle />
            {error}
          </div>
        )}

        <Textarea
          ref={commitTextareaRef}
          value={commitMessage}
          onChange={(e) => onCommitMessageChange(e.target.value)}
          onKeyDown={handleKeyDown}
          placeholder={t("git.commitMessagePlaceholder")}
          variant="ghost"
          className={cn(
            "max-h-32 min-h-16 w-full resize-none overflow-x-hidden bg-transparent",
            "font-sans ui-text-sm px-3 pt-3 pb-2 text-foreground placeholder:text-subtle-foreground",
            "focus:outline-none",
          )}
          rows={2}
          disabled={isCommitting}
        />
      </SidebarComposerBody>

      <div className="flex flex-wrap items-center gap-x-2 gap-y-1 px-1 pt-1.5">
        <div className="flex min-w-0 flex-1 flex-wrap items-center gap-1">
          <span className="px-1 ui-text-sm text-subtle-foreground">
            {selectedFilesCount > 0
              ? t(selectedFilesCount === 1 ? "git.fileSelected" : "git.filesSelected", {
                  count: selectedFilesCount,
                })
              : t("git.noFilesSelected")}
          </span>

          {hasRemoteChanges && (
            <div className="flex items-center gap-1">
              {ahead > 0 && (
                <Button
                  type="button"
                  onClick={() => void handlePush()}
                  disabled={!repoPath || isRemoteActionLoading || isPulling}
                  variant="ghost"
                  size="xs"
                  className={cn(composerButtonClassName, "text-git-added hover:text-git-added")}
                  tooltip={`Push ${ahead} commit${ahead !== 1 ? "s" : ""}`}
                >
                  <ArrowUp />
                  <span>{ahead}</span>
                </Button>
              )}

              {behind > 0 && (
                <Button
                  type="button"
                  onClick={() => void onPull?.()}
                  disabled={!repoPath || isRemoteActionLoading || isPulling}
                  variant="ghost"
                  size="xs"
                  className={cn(composerButtonClassName, "text-git-deleted hover:text-git-deleted")}
                  tooltip={`Pull ${behind} commit${behind !== 1 ? "s" : ""}`}
                >
                  <ArrowDown />
                  <span>{behind}</span>
                </Button>
              )}
            </div>
          )}
        </div>

        <div className="flex shrink-0 items-center gap-1">
          <ButtonGroup ref={generateMenuAnchorRef}>
            <Button
              type="button"
              variant="default"
              size="xs"
              onClick={() => void handleGenerateCommitMessage()}
              disabled={isGenerateDisabled}
              tooltip={t("git.generateCommitMessageWithAI")}
              aria-label={t("git.generateCommitMessageWithAI")}
            >
              <Sparkles />
            </Button>
            <ButtonGroupSeparator />
            <Button
              type="button"
              variant="default"
              size="icon-xs"
              onClick={() => setIsGenerateModeMenuOpen((open) => !open)}
              disabled={isGenerating || isCommitting}
              active={isGenerateModeMenuOpen}
              tooltip={t("git.commitMessageFormat")}
              aria-label={t("git.commitMessageFormat")}
              aria-haspopup="menu"
              aria-expanded={isGenerateModeMenuOpen}
            >
              <ChevronDown />
            </Button>
          </ButtonGroup>
          <Dropdown
            isOpen={isGenerateModeMenuOpen}
            anchorRef={generateMenuAnchorRef}
            anchorAlign="end"
            onClose={() => setIsGenerateModeMenuOpen(false)}
            items={generateModeItems}
            className="min-w-37.5"
          />

          <ButtonGroup ref={commitMenuAnchorRef}>
            <Button
              type="button"
              onClick={() => void handleCommit()}
              disabled={isCommitDisabled}
              variant="ghost"
              size="xs"
              className={cn(
                composerButtonClassName,
                isCommitDisabled
                  ? "cursor-not-allowed text-subtle-foreground opacity-50"
                  : "text-primary hover:bg-primary/8 hover:text-primary/80",
              )}
            >
              {isCommitting ? t("git.committing") : t("git.commit")}
            </Button>
            <ButtonGroupSeparator />
            <Button
              type="button"
              variant="ghost"
              size="icon-xs"
              onClick={() => setIsCommitActionMenuOpen((open) => !open)}
              disabled={isCommitDisabled || isRemoteActionLoading || isPulling}
              active={isCommitActionMenuOpen}
              className={cn(
                composerButtonClassName,
                "px-1 text-primary hover:bg-primary/8 hover:text-primary/80",
              )}
              tooltip={t("git.chooseCommitAction")}
              aria-label={t("git.chooseCommitAction")}
              aria-haspopup="menu"
              aria-expanded={isCommitActionMenuOpen}
            >
              <ChevronDown />
            </Button>
          </ButtonGroup>
          <Dropdown
            isOpen={isCommitActionMenuOpen}
            anchorRef={commitMenuAnchorRef}
            anchorAlign="end"
            onClose={() => setIsCommitActionMenuOpen(false)}
            items={commitActionItems}
            className="min-w-37.5"
          />
        </div>
      </div>
    </>
  );
};

export default GitCommitPanel;
