import {
  ArrowDownIcon as ArrowDown,
  ArrowUpIcon as ArrowUp,
  CaretDownIcon as ChevronDown,
  WarningCircleIcon as AlertCircle,
  SparkleIcon as Sparkles,
  GearSixIcon as SettingsIcon,
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
  commitAIError,
  collectCommitFiles,
  commitSelectionKey,
  generateCommitMessage,
} from "../services/ai-commit-service";
import { generateCommitDraft } from "../services/ai-commit-workflow";
import { showConfirmDialog } from "@/ui/dialog";
import { useUIState } from "@/features/window/stores/ui-state.store";
import { commitSelectedChanges } from "../api/git-commits-api";
import { showGitPushDialog } from "../services/git-push-dialog-service";
import { useGitBlameStore } from "../stores/git-blame.store";
import { useGitStore } from "../stores/git.store";
import type { GitFile } from "../types/git.types";
import {
  getGitFileRepositoryPath,
  resolveGitFileMutationPaths,
} from "../utils/git-status-selection";

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
  isPullLocked?: boolean;
  focusRequest?: number;
}

const COMMIT_TEXTAREA_MIN_HEIGHT = 64;
const COMMIT_TEXTAREA_MAX_HEIGHT = 128;

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
  const [isCommitting, setIsCommitting] = useState(false);
  const [isGenerating, setIsGenerating] = useState(false);
  const [isCommitActionMenuOpen, setIsCommitActionMenuOpen] = useState(false);
  const [remoteAction, setRemoteAction] = useState<"push" | null>(null);
  const [error, setError] = useState<string | null>(null);
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
    if (selectedFilesCount === 0) {
      setError(t("git.selectFilesToCommit"));
      return;
    }
    if (!repoPath || !commitMessage.trim()) return;
    const selectedRepoPaths = new Set(
      selectedFiles.map((file) => getGitFileRepositoryPath(file, repoPath) ?? repoPath),
    );
    if (selectedRepoPaths.size > 1 || !selectedRepoPaths.has(repoPath)) {
      setError(t("git.selectSingleRepositoryForCommit"));
      return;
    }

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
  const isGenerateDisabled =
    selectedFilesCount === 0 || isGenerating || isCommitting || !aiSettings.enabled;
  const hasRemoteChanges = ahead > 0 || behind > 0;
  const isRemoteActionLoading = remoteAction !== null;
  const composerButtonClassName =
    "h-6 rounded-md border-transparent bg-transparent px-1.5 ui-text-sm leading-none text-subtle-foreground shadow-none hover:bg-accent/80 hover:text-foreground focus-visible:ring-1 focus-visible:ring-border-strong/35 [&_svg]:size-3";
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
                  disabled={!repoPath || isRemoteActionLoading || isPullLocked}
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
          <Button
            type="button"
            size="xs"
            onClick={() => openSettings("ai-commit")}
            tooltip={t("aiCommit.settings")}
            aria-label={t("aiCommit.settings")}
          >
            <SettingsIcon />
          </Button>
          {isGenerating ? (
            <Button
              type="button"
              size="xs"
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
              onClick={() => void handleGenerateCommitMessage()}
              disabled={isGenerateDisabled}
              tooltip={t("git.generateCommitMessageWithAI")}
              aria-label={t("git.generateCommitMessageWithAI")}
            >
              <Sparkles />
              <span>AI</span>
            </Button>
          )}

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
