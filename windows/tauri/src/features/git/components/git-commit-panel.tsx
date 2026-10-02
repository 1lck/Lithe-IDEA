import {
  ArrowDownIcon as ArrowDown,
  ArrowUpIcon as ArrowUp,
  WarningCircleIcon as AlertCircle,
  SparkleIcon as Sparkles,
  GearSixIcon as SettingsIcon,
} from "@/ui/icons";
import type React from "react";
import { useEffect, useMemo, useRef, useState, useSyncExternalStore } from "react";
import { useWorkspaceCommitStore } from "../stores/git-workspace-commit.store";
import { workspaceCommitBindings } from "../utils/git-workspace-commit-bindings";
import { GitWorkspaceCommitReview } from "./git-workspace-commit-review";
import { workspaceCommitEnglish } from "@/i18n/git-workspace-commit";
import type { TranslationKey } from "@/i18n/locale";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import { SidebarComposerBody } from "@/ui/sidebar";
import Textarea from "@/ui/textarea";
import { cn } from "@/utils/cn";
import { IDEA_BUTTON_CLASS_NAME } from "../utils/idea-control-styles";
import {
  commitAIError,
  collectCommitFiles,
  commitSelectionKey,
  generateCommitMessage,
} from "../services/ai-commit-service";
import { generateCommitDraft } from "../services/ai-commit-workflow";
import { showConfirmDialog } from "@/ui/dialog";
import { useUIState } from "@/features/window/stores/ui-state.store";
import { showGitPushDialog } from "../services/git-push-dialog-service";
import {
  useActiveWorkspaceId,
  useWorkspaceReady,
  useWorkspaceStoreScopeId,
} from "@/features/workspace/stores/create-workspace-scoped-store";
import type { GitFile } from "../types/git.types";
import { COMMIT_MESSAGE_MAX_VIEWPORT_RATIO } from "../hooks/use-git-commit-area-resize";

interface GitCommitPanelProps {
  selectedFiles: GitFile[];
  workspacePath: string;
  repositoryPaths: string[];
  isStaging?: boolean;
  commitMessage: string;
  onCommitMessageChange: (message: string) => void;
  currentBranch?: string;
  repoPath?: string;
  ahead?: number;
  behind?: number;
  onPull?: () => Promise<unknown> | void;
  isPulling?: boolean;
  isPullLocked?: boolean;
  focusRequest?: number;
}


// IntelliJ CommitLegendComponent: "N added   N modified   N deleted", each part
// tinted with its file-status color. Untracked files count as added (shown as
// "new+unversioned") and renames count as modified, as in ChangeInfoCalculator.
interface CommitLegendChunk {
  id: "added" | "modified" | "deleted";
  value: string;
  labelKey: "git.changeAdded" | "git.changeModified" | "git.changeDeleted";
  className: string;
}

function buildCommitLegend(files: GitFile[]): CommitLegendChunk[] {
  let added = 0;
  let untracked = 0;
  let modified = 0;
  let deleted = 0;
  for (const file of files) {
    if (file.status === "added") added += 1;
    else if (file.status === "untracked") untracked += 1;
    else if (file.status === "deleted") deleted += 1;
    else modified += 1;
  }
  const chunks: CommitLegendChunk[] = [];
  if (added > 0 || untracked > 0) {
    chunks.push({
      id: "added",
      value: added > 0 && untracked > 0 ? `${added}+${untracked}` : String(added || untracked),
      labelKey: "git.changeAdded",
      className: "text-git-added",
    });
  }
  if (modified > 0) {
    chunks.push({
      id: "modified",
      value: String(modified),
      labelKey: "git.changeModified",
      className: "text-git-modified",
    });
  }
  if (deleted > 0) {
    chunks.push({
      id: "deleted",
      value: String(deleted),
      labelKey: "git.changeDeleted",
      className: "text-git-file-deleted",
    });
  }
  return chunks;
}

const GitCommitPanel = ({
  selectedFiles,
  workspacePath,
  repositoryPaths,
  isStaging = false,
  commitMessage,
  onCommitMessageChange,
  currentBranch,
  repoPath,
  ahead = 0,
  behind = 0,
  onPull,
  isPulling = false,
  isPullLocked = false,
  focusRequest = 0,
}: GitCommitPanelProps) => {
  const { t } = useTranslation();
  const aiSettings = useSettingsStore((state) => state.settings.aiCommit);
  const openSettings = useUIState((state) => state.openSettingsDialog);
  const generationRef = useRef<AbortController | null>(null);
  const selection = commitSelectionKey(repoPath ?? "", selectedFiles) + (currentBranch ?? "");
  const currentDraft = useRef({ selection, message: commitMessage, apply: onCommitMessageChange });
  currentDraft.current = { selection, message: commitMessage, apply: onCommitMessageChange };
  useEffect(() => {
    generationRef.current?.abort();
    generationRef.current = null;
    setIsGenerating(false);
    return () => {
      generationRef.current?.abort();
      generationRef.current = null;
    };
  }, [selection]);
  const workflow = useWorkspaceCommitStore((state) => state.workflow);
  const batch = useSyncExternalStore(workflow.subscribe, workflow.getState, workflow.getState);
  const isCommitting = batch.busy;
  const activeWorkspaceId = useActiveWorkspaceId();
  const workspaceId = useWorkspaceStoreScopeId() ?? activeWorkspaceId;
  const workspaceReady = useWorkspaceReady(workspaceId);
  const isCurrentWorkspace = workspaceReady && workspaceId === activeWorkspaceId;
  const setDraftOwner = useWorkspaceCommitStore((state) => state.setDraftOwner);
  const [isGenerating, setIsGenerating] = useState(false);
  const [remoteAction, setRemoteAction] = useState<"push" | null>(null);
  const [error, setError] = useState<string | null>(null);
  // IntelliJ CommitProgressPanel: the buttons stay enabled and a click with nothing
  // to commit explains what is missing until the selection or message changes.
  const [commitHint, setCommitHint] = useState<{ noChanges: boolean; noMessage: boolean } | null>(
    null,
  );
  const commitTextareaRef = useRef<HTMLTextAreaElement>(null);
  const selectedFilesCount = selectedFiles.length;

  useEffect(() => {
    if (focusRequest <= 0) return;
    globalThis.requestAnimationFrame?.(() => commitTextareaRef.current?.focus());
  }, [focusRequest]);

  const handleGenerateCommitMessage = async () => {
    if (!repoPath || selectedFilesCount === 0 || generationRef.current || !aiSettings.enabled)
      return;
    if (!aiSettings.providers.some((p) => p.id === aiSettings.activeProviderId)) {
      setError(t("aiCommit.configure"));
      openSettings("ai-commit");
      return;
    }
    const controller = new AbortController();
    generationRef.current = controller;
    setError(null);
    setIsGenerating(true);
    try {
      await generateCommitDraft({
        signal: controller.signal,
        current: () => currentDraft.current,
        readFiles: () => collectCommitFiles(repoPath, selectedFiles, controller.signal),
        generate: (files) => generateCommitMessage(aiSettings, files, controller.signal),
        confirmReplace: () => showConfirmDialog(t("aiCommit.replace")),
        apply: (message) => currentDraft.current.apply(message),
      });
    } catch (error) {
      if (!controller.signal.aborted) setError(commitAIError(error, t));
    } finally {
      if (generationRef.current === controller) {
        generationRef.current = null;
        setIsGenerating(false);
      }
    }
  };

  const handleCommit = async (pushAfterCommit = false) => {
    if (
      !isCurrentWorkspace ||
      isStaging ||
      batch.busy ||
      batch.review ||
      (batch.session && !batch.session.succeeded)
    )
      return;
    const noChanges = selectedFilesCount === 0;
    const noMessage = !commitMessage.trim();
    if (noChanges || noMessage) {
      setCommitHint({ noChanges, noMessage });
      if (noMessage && !noChanges) commitTextareaRef.current?.focus();
      return;
    }
    if (!repoPath) return;
    setCommitHint(null);
    setDraftOwner(repoPath);
    setError(null);
    await workflow.prepare({
      repositories: workspaceCommitBindings(workspacePath, repositoryPaths),
      message: commitMessage.trim(),
      amend: false,
      push: pushAfterCommit,
      includeParentReferences: true,
    });
  };

  const handleRetry = () => {
    const previous = batch.session;
    if (!previous?.canRetry || isStaging || !isCurrentWorkspace) return;
    setError(null);
    return workflow.prepare({
      repositories: workspaceCommitBindings(workspacePath, repositoryPaths),
      message: previous.plan.message,
      amend: previous.plan.amend,
      push: previous.plan.push,
      includeParentReferences: previous.plan.includeParentReferences,
      previous,
    });
  };

  const handlePush = async () => {
    if (!repoPath || isCommitting) return;

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

  // Missing files or message no longer grey the buttons out (see commitHint); only
  // states where a click cannot start a commit at all still disable them.
  const isCommitDisabled =
    !isCurrentWorkspace ||
    isStaging ||
    Boolean(batch.review) ||
    Boolean(batch.session && !batch.session.succeeded) ||
    isCommitting ||
    isGenerating;
  const isGenerateDisabled =
    selectedFilesCount === 0 || isGenerating || isCommitting || !aiSettings.enabled;
  const isRemoteActionLoading = remoteAction !== null;
  const composerButtonClassName =
    "h-6 rounded-md border-transparent bg-transparent px-1.5 ui-text-sm leading-none text-subtle-foreground shadow-none hover:bg-accent/80 hover:text-foreground focus-visible:ring-1 focus-visible:ring-border-strong/35 [&_svg]:size-3";
  const isCommitAndPushDisabled = isCommitDisabled || isRemoteActionLoading || isPulling;

  const hasNoChanges = selectedFilesCount === 0;
  const hasNoMessage = !commitMessage.trim();
  // Drop each part of the hint as soon as the user fixes it, like clearError().
  const visibleCommitHint =
    commitHint && ((commitHint.noChanges && hasNoChanges) || (commitHint.noMessage && hasNoMessage))
      ? {
          noChanges: commitHint.noChanges && hasNoChanges,
          noMessage: commitHint.noMessage && hasNoMessage,
        }
      : null;
  const commitHintText = visibleCommitHint
    ? t(
        visibleCommitHint.noChanges && visibleCommitHint.noMessage
          ? "git.selectFilesAndSpecifyCommitMessage"
          : visibleCommitHint.noChanges
            ? "git.selectFilesToCommit"
            : "git.specifyCommitMessage",
      )
    : null;
  const hasError = Boolean(error || batch.error || visibleCommitHint?.noMessage);
  const commitLegend = useMemo(() => buildCommitLegend(selectedFiles), [selectedFiles]);

  return (
    // IntelliJ NonModalCommitPanel order: status row (legend), commit message, then
    // commit actions with the options button pushed right.
    <div className="group/commit-panel flex flex-col gap-1.5 px-2 pt-2 pb-1">
      {commitLegend.length > 0 ? (
        <div className="flex min-h-6 items-center gap-2">
          <span
            className="ml-auto flex min-w-0 flex-wrap justify-end gap-x-3 ui-text-sm"
            data-testid="git-commit-legend"
          >
            {commitLegend.map((chunk) => (
              <span key={chunk.id} className={cn("whitespace-nowrap", chunk.className)}>
                {chunk.value} {t(chunk.labelKey)}
              </span>
            ))}
          </span>
        </div>
      ) : null}

      <SidebarComposerBody
        variant="plain"
        className={cn(
          // IntelliJ CommitInputBorder look: 1px neutral border, 2px accent
          // (border + outer ring) when focused, error outline on failures.
          "relative z-10 rounded-[4px] border bg-background transition-[border-color,box-shadow] duration-(--app-duration-fast) ease-(--app-ease-smooth)",
          hasError ? "border-destructive/60" : "border-control-border",
          "focus-within:border-primary focus-within:ring-1 focus-within:ring-primary",
          hasError && "focus-within:border-destructive focus-within:ring-destructive",
        )}
      >
        {(error || batch.error) && (
          <div
            className={cn(
              "mx-2 mt-2 flex items-center gap-2 rounded-md border border-destructive/30",
              "bg-destructive/20 px-2 py-1 ui-text-sm text-destructive",
            )}
          >
            <AlertCircle />
            {error || batch.error}
          </div>
        )}

        {batch.session && (
          <div className="max-h-40 overflow-auto px-3 py-2 ui-text-sm" aria-live="polite">
            {Object.entries(batch.session.results).map(([id, result]) => {
              const key = `git.workspaceCommit.${result.status}`;
              const label =
                key in workspaceCommitEnglish
                  ? (key as TranslationKey)
                  : "git.workspaceCommit.attention";
              return (
                <div key={id} className="break-words">
                  <strong>{id}</strong>: {t(label)}
                  {result.detail && <p className="whitespace-pre-wrap">{result.detail}</p>}
                </div>
              );
            })}
            {!isCommitting && (
              <div className="flex flex-wrap gap-2">
                {batch.session.canRetry && (
                  <Button
                    size="xs"
                    onClick={() => void handleRetry()}
                    disabled={Boolean(batch.review) || isStaging}
                  >
                    {t("git.workspaceCommit.retry")}
                  </Button>
                )}
                <Button size="xs" onClick={workflow.dismiss}>
                  {t("git.workspaceCommit.dismiss")}
                </Button>
              </div>
            )}
          </div>
        )}
        {isCommitting && (
          <Button size="xs" onClick={workflow.cancel}>
            {t("git.workspaceCommit.stop")}
          </Button>
        )}
        {batch.review && isCurrentWorkspace && (
          <GitWorkspaceCommitReview
            preparation={batch.review.preparation}
            busy={isCommitting || isStaging}
            error={batch.error}
            onConfirm={() =>
              void workflow.confirm(workspaceCommitBindings(workspacePath, repositoryPaths))
            }
            onClose={workflow.closeReview}
            onIncludeParents={(include) =>
              void workflow.setIncludeParentReferences(
                include,
                workspaceCommitBindings(workspacePath, repositoryPaths),
              )
            }
          />
        )}

        <Textarea
          ref={commitTextareaRef}
          value={commitMessage}
          onChange={(e) => onCommitMessageChange(e.target.value)}
          onKeyDown={handleKeyDown}
          placeholder={t("git.commitMessagePlaceholder")}
          variant="ghost"
          className={cn(
            "w-full resize-none overflow-x-hidden overflow-y-auto bg-transparent",
            "font-sans ui-text-sm px-2 py-1.5 text-foreground placeholder:text-subtle-foreground",
            "focus:outline-none",
          )}
          // The height follows the divider above the commit area (see
          // useGitCommitAreaResize); the cap keeps a short window usable.
          style={{
            height: `min(var(--git-commit-message-height, 72px), var(--git-commit-message-max-height, 640px), ${COMMIT_MESSAGE_MAX_VIEWPORT_RATIO * 100}vh)`,
          }}
          disabled={isCommitting}
        />
      </SidebarComposerBody>

      {commitHintText ? (
        <div
          role="alert"
          className="flex items-center gap-1.5 ui-text-sm text-destructive"
          data-testid="git-commit-hint"
        >
          <AlertCircle className="size-3.5 shrink-0" />
          {commitHintText}
        </div>
      ) : null}

      <div className="flex flex-wrap items-center gap-1.5">
        <Button
          type="button"
          size="sm"
          onClick={() => void handleCommit()}
          disabled={isCommitDisabled}
          className={cn(
            IDEA_BUTTON_CLASS_NAME,
            // IntelliJ makes Commit the blue default button while focus is inside the
            // commit area (typically the message), so Ctrl+Enter visibly targets it and
            // the highlight survives moving focus onto the button itself.
            "group-focus-within/commit-panel:border-primary group-focus-within/commit-panel:bg-primary group-focus-within/commit-panel:text-white group-focus-within/commit-panel:hover:bg-primary/90",
          )}
          data-commit-default-button=""
        >
          {isCommitting ? t("git.committing") : t("git.commit")}
        </Button>
        <Button
          type="button"
          size="sm"
          onClick={() => void handleCommit(true)}
          disabled={isCommitAndPushDisabled}
          className={IDEA_BUTTON_CLASS_NAME}
        >
          {t("git.commitAndPushEllipsis")}
        </Button>

        <div className="ml-auto flex items-center gap-1">
          {ahead > 0 && (
            <Button
              type="button"
              onClick={() => void handlePush()}
              disabled={!repoPath || isCommitting || isRemoteActionLoading || isPulling}
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
              disabled={!repoPath || isCommitting || isRemoteActionLoading || isPullLocked}
              variant="ghost"
              size="xs"
              className={cn(composerButtonClassName, "text-git-deleted hover:text-git-deleted")}
              tooltip={`Pull ${behind} commit${behind !== 1 ? "s" : ""}`}
            >
              <ArrowDown />
              <span>{behind}</span>
            </Button>
          )}
          {isGenerating ? (
            <Button
              type="button"
              size="xs"
              variant="ghost"
              className={composerButtonClassName}
              onClick={() => {
                generationRef.current?.abort();
                generationRef.current = null;
                setIsGenerating(false);
              }}
            >
              {t("aiCommit.cancel")}
            </Button>
          ) : (
            <Button
              type="button"
              size="xs"
              variant="ghost"
              className={composerButtonClassName}
              onClick={() => void handleGenerateCommitMessage()}
              disabled={isGenerateDisabled}
              tooltip={t("git.generateCommitMessageWithAI")}
              aria-label={t("git.generateCommitMessageWithAI")}
            >
              <Sparkles />
              <span>AI</span>
            </Button>
          )}
          <Button
            type="button"
            size="icon-xs"
            variant="ghost"
            onClick={() => openSettings("ai-commit")}
            tooltip={t("aiCommit.settings")}
            aria-label={t("aiCommit.settings")}
          >
            <SettingsIcon />
          </Button>
        </div>
      </div>
    </div>
  );
};

export default GitCommitPanel;
