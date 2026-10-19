import type { WorkspaceCommitPathScope } from "../types/git-workspace-commit.types";
import { Checkbox } from "@/ui/checkbox";
import {
  ClockCounterClockwiseIcon as History,
  WarningCircleIcon as AlertCircle,
  CommitMagicIcon as Sparkles,
  GearSixIcon as SettingsIcon,
} from "@/ui/icons";
import type React from "react";
import { useEffect, useMemo, useRef, useState, useSyncExternalStore } from "react";
import { useWorkspaceCommitStore } from "../stores/git-workspace-commit.store";
import { commitDiffWritePending } from "../runtime/commit-diff-write-state";
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
import { IDEA_BUTTON_CLASS_NAME, IDEA_CHECKBOX_CLASS_NAME } from "../utils/idea-control-styles";
import "./git-commit-panel.css";
import {
  commitAIError,
  collectCommitFiles,
  commitSelectionKey,
  generateCommitMessage,
} from "../services/ai-commit-service";
import { generateCommitDraft } from "../services/ai-commit-workflow";
import { showConfirmDialog } from "@/ui/dialog";
import { useUIState } from "@/features/window/stores/ui-state.store";
import {
  useActiveWorkspaceId,
  useWorkspaceReady,
  useWorkspaceStoreScopeId,
} from "@/features/workspace/stores/create-workspace-scoped-store";
import type { GitFile } from "../types/git.types";
import { COMMIT_MESSAGE_MAX_VIEWPORT_RATIO } from "../hooks/use-git-commit-area-resize";
import { COMMIT_MESSAGE_DEFAULT_HEIGHT } from "../stores/git-commit-panel-preferences.store";

interface GitCommitPanelProps {
  pathScope?: WorkspaceCommitPathScope;
  includeParentReferences?: boolean;
  commitScopeError?: string;
  selectedFiles: GitFile[];
  workspacePath: string;
  repositoryPaths: string[];
  isStaging?: boolean;
  commitMessage: string;
  onCommitMessageChange: (message: string) => void;
  currentBranch?: string;
  repoPath?: string;
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
  pathScope,
  includeParentReferences = true,
  commitScopeError,
  selectedFiles,
  workspacePath,
  repositoryPaths,
  isStaging = false,
  commitMessage,
  onCommitMessageChange,
  currentBranch,
  repoPath,
  focusRequest = 0,
}: GitCommitPanelProps) => {
  const { t } = useTranslation();
  const [amend, setAmend] = useState(false);
  useEffect(() => setAmend(false), [repoPath, currentBranch]);
  const aiSettings = useSettingsStore((state) => state.settings.aiCommit);
  const openSettings = useUIState((state) => state.openSettingsDialog);
  const generationRef = useRef<AbortController | null>(null);
  const selection =
    commitSelectionKey(repoPath ?? "", selectedFiles) + (currentBranch ?? "") + String(amend);
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
  useEffect(() => {
    if (batch.session?.succeeded) setAmend(false);
  }, [batch.session?.succeeded]);
  const activeWorkspaceId = useActiveWorkspaceId();
  const workspaceId = useWorkspaceStoreScopeId() ?? activeWorkspaceId;
  const workspaceReady = useWorkspaceReady(workspaceId);
  const isCurrentWorkspace = workspaceReady && workspaceId === activeWorkspaceId;
  const setDraftOwner = useWorkspaceCommitStore((state) => state.setDraftOwner);
  const [isGenerating, setIsGenerating] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // Keyboard submission keeps actionable validation even while empty buttons are disabled.
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
      commitScopeError ||
      isStaging ||
      commitDiffWritePending() ||
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
      amend,
      push: pushAfterCommit,
      includeParentReferences,
      pathScope,
    });
  };

  const handleRetry = () => {
    const previous = batch.session;
    if (!previous?.canRetry || isStaging || commitDiffWritePending() || !isCurrentWorkspace) return;
    setError(null);
    return workflow.prepare({
      repositories: workspaceCommitBindings(workspacePath, repositoryPaths),
      message: previous.plan.message,
      amend: previous.plan.amend,
      push: previous.plan.push,
      includeParentReferences: previous.plan.includeParentReferences,
      pathScope: previous.plan.pathScope,
      previous,
    });
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
    Boolean(commitScopeError) ||
    !isCurrentWorkspace ||
    isStaging ||
    Boolean(batch.review) ||
    Boolean(batch.session && !batch.session.succeeded) ||
    isCommitting ||
    isGenerating;
  const isGenerateDisabled =
    selectedFilesCount === 0 || isGenerating || isCommitting || !aiSettings.enabled;
  const composerButtonClassName =
    "git-commit-ai shrink-0 border border-control-border bg-checkbox-background leading-none text-foreground shadow-none hover:bg-accent [&_svg]:size-4";

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
  const hasError = Boolean(
    error || batch.error || commitScopeError || visibleCommitHint?.noMessage,
  );
  const commitLegend = useMemo(() => buildCommitLegend(selectedFiles), [selectedFiles]);

  return (
    // Match the reference composer: Amend, AI and selection count above the
    // message; commit actions and settings below it.
    <div className="group/commit-panel git-commit-panel">
      <div className="git-commit-metadata">
        <div className="git-commit-amend">
          <label className="flex items-center gap-1.5 ui-text-sm whitespace-nowrap">
            <Checkbox
              className={IDEA_CHECKBOX_CLASS_NAME}
              aria-label={t("git.amend") + t("git.amendLastCommit")}
              checked={amend}
              onCheckedChange={setAmend}
              disabled={isCommitting || Boolean(batch.review)}
            />
            <span>
              {t("git.amend")}
              <span className="text-primary">{t("git.amendLastCommit")}</span>
            </span>
          </label>
          <History className="size-4 shrink-0" aria-hidden="true" />
        </div>
        <span className="min-w-0 flex-1" />
        {isGenerating ? (
          <Button
            type="button"
            size="xs"
            variant="default"
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
            variant="default"
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
        <span
          className="git-commit-count text-subtle-foreground"
          title={commitLegend.map((chunk) => `${chunk.value} ${t(chunk.labelKey)}`).join(", ")}
        >
          {t("git.stagedFilesCount", { count: selectedFilesCount })}
        </span>
      </div>

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
        {(error || batch.error || commitScopeError) && (
          <div
            className={cn(
              "mx-2 mt-2 flex items-center gap-2 rounded-md border border-destructive/30",
              "bg-destructive/20 px-2 py-1 ui-text-sm text-destructive",
            )}
          >
            <AlertCircle />
            {error || batch.error || commitScopeError}
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
            "block w-full resize-none overflow-x-hidden overflow-y-auto bg-transparent",
            "font-mono ui-text-sm px-[9px] py-[3px] text-foreground placeholder:text-subtle-foreground",
            "focus:outline-none",
          )}
          // The height follows the divider above the commit area (see
          // useGitCommitAreaResize); the cap keeps a short window usable.
          style={{
            height: `min(var(--git-commit-message-height, ${COMMIT_MESSAGE_DEFAULT_HEIGHT}px), var(--git-commit-message-max-height, 640px), ${COMMIT_MESSAGE_MAX_VIEWPORT_RATIO * 100}vh)`,
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

      <div className="git-commit-actions">
        <Button
          type="button"
          size="sm"
          onClick={() => void handleCommit()}
          disabled={isCommitDisabled}
          className={cn(
            IDEA_BUTTON_CLASS_NAME,
            "enabled:border-primary enabled:bg-primary enabled:text-white enabled:hover:bg-primary/90",
          )}
          data-commit-default-button=""
        >
          <span className="truncate">{isCommitting ? t("git.committing") : t("git.commit")}</span>
        </Button>
        <Button
          type="button"
          size="sm"
          onClick={() => void handleCommit(true)}
          disabled={isCommitDisabled}
          className={IDEA_BUTTON_CLASS_NAME}
          title={t("git.commitAndPushEllipsis")}
          aria-label={t("git.commitAndPushEllipsis")}
        >
          <span className="truncate">{t("git.commitAndPushEllipsis")}</span>
        </Button>

        <div className="ml-auto shrink-0">
          <Button
            type="button"
            size="icon-xs"
            variant="ghost"
            className="[&_svg]:size-4"
            onClick={() => openSettings("ai-commit")}
            tooltip={t("aiCommit.settings")}
            aria-label={t("aiCommit.settings")}
            data-commit-settings=""
          >
            <SettingsIcon />
          </Button>
        </div>
      </div>
    </div>
  );
};

export default GitCommitPanel;
