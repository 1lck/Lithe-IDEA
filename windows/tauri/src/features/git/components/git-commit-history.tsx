import {
  ArrowCounterClockwiseIcon as Reset,
  FunnelIcon as Funnel,
  GitCommitIcon as CherryPick,
  GitMergeIcon as Squash,
  PencilIcon as Edit,
  TrashIcon as Trash,
} from "@/ui/icons";
import { memo, useCallback, useEffect, useMemo, useRef, useState } from "react";
import type React from "react";
import { writeSidebarResourceDragData } from "@/features/sidebar/utils/sidebar-resource-drag";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuRadioGroup,
  DropdownMenuRadioItem,
  DropdownMenuTrigger,
  Dropdown,
  useDropdownMenu,
  type MenuItem,
} from "@/ui/dropdown";
import { Spinner } from "@/ui/spinner";
import { Avatar } from "@/ui/avatar";
import { EmptyState } from "@/ui/empty";
import { SidebarHeaderIconButton, SidebarHeader, SidebarSearchPopover } from "@/ui/sidebar";
import { formatRelativeDate } from "@/utils/date";
import { matchesSearchQuery } from "@/utils/search-match";
import { cn } from "@/utils/cn";
import { useTranslation } from "@/i18n/locale-provider";
import { showChoiceDialog, showConfirmDialog, showPromptDialog } from "@/ui/dialog";
import { toast } from "sonner";
import type { GitCommit } from "../types/git.types";
import { useGitStore } from "../stores/git.store";
import { getGitAuthorAvatarUrl } from "../utils/git-author-avatar";
import {
  cherryPickCommit,
  deleteCommit,
  editCommitMessage,
  resetToCommit,
  squashCommits,
  type GitResetMode,
} from "../api/git-commits-api";
import {
  isContiguousGitHistorySelection,
  resolveGitHistoryContextSelection,
  selectedCommitsInHistoryOrder,
  updateGitHistorySelection,
} from "../utils/git-history-selection";

interface GitCommitHistoryProps {
  onViewCommitDiff?: (commitHash: string, filePath?: string) => void;
  repoPath?: string;
  ahead?: number;
  behind?: number;
}

interface CommitItemProps {
  commit: GitCommit;
  onSelect: (event: React.MouseEvent, commit: GitCommit) => void;
  onContextMenu: (event: React.MouseEvent, commit: GitCommit) => void;
  isSelected: boolean;
  syncState: "local" | "pushed";
  repoPath?: string;
}

type HistorySearchScope = "all" | "message" | "author" | "hash";

const HISTORY_SEARCH_SCOPE_KEYS: Record<HistorySearchScope, string> = {
  all: "git.historyFilterAll",
  message: "git.historyFilterMessage",
  author: "git.historyFilterAuthor",
  hash: "git.historyFilterHash",
};

function getCommitSearchFields(commit: GitCommit, scope: HistorySearchScope) {
  if (scope === "message") return [commit.message, commit.description ?? ""];
  if (scope === "author") return [commit.author, commit.email ?? ""];
  if (scope === "hash") return [commit.hash, commit.hash.substring(0, 7)];

  return [
    commit.message,
    commit.description ?? "",
    commit.author,
    commit.email ?? "",
    commit.hash,
    commit.hash.substring(0, 7),
  ];
}

const CommitItem = memo(
  ({
    commit,
    onSelect,
    onContextMenu,
    isSelected,
    syncState,
    repoPath,
  }: CommitItemProps) => {
    const shortHash = commit.hash.substring(0, 7);
    const avatarUrl = getGitAuthorAvatarUrl(commit);

    return (
      <div className="mb-0.5">
        <button
          type="button"
          onClick={(event) => onSelect(event, commit)}
          onContextMenu={(event) => onContextMenu(event, commit)}
          aria-pressed={isSelected}
          className={cn(
            "ui-text-sm flex w-full cursor-pointer items-start gap-2.5 rounded-md px-2.5 py-1.5 text-left outline-none transition-colors hover:bg-accent/80 focus-visible:bg-accent/80",
            isSelected && "bg-primary/10",
          )}
          draggable={!!repoPath}
          onDragStart={(event) => {
            if (!repoPath) return;
            writeSidebarResourceDragData(event.dataTransfer, {
              type: "git-commit",
              repoPath,
              commitHash: commit.hash,
              message: commit.message,
              author: commit.author,
              date: commit.date,
              name: `Commit ${shortHash}`,
            });
          }}
        >
          <Avatar name={commit.author} src={avatarUrl} className="mt-0.5 size-6" />
          <span className="min-w-0 flex-1">
            <span className="flex min-w-0 items-center gap-2">
              <span
                className={cn(
                  "truncate leading-tight",
                  syncState === "local" ? "text-primary" : "text-foreground",
                )}
              >
                {commit.message}
              </span>
              {syncState === "local" ? (
                <span className="size-1.5 shrink-0 rounded-full bg-primary" />
              ) : null}
            </span>
            <span className="ui-text-sm mt-1 flex min-w-0 items-center gap-2 text-subtle-foreground">
              <span className="truncate">{commit.author}</span>
              <span className="shrink-0">{formatRelativeDate(commit.date)}</span>
              <span className="shrink-0 font-mono">{shortHash}</span>
            </span>
          </span>
        </button>
      </div>
    );
  },
);

const GitCommitHistory = ({
  onViewCommitDiff,
  repoPath,
  ahead = 0,
  behind = 0,
}: GitCommitHistoryProps) => {
  const { t } = useTranslation();
  const commits = useGitStore((state) => state.commits);
  const hasMoreCommits = useGitStore((state) => state.hasMoreCommits);
  const isLoadingMoreCommits = useGitStore((state) => state.isLoadingMoreCommits);
  const actions = useGitStore((state) => state.actions);
  const scrollContainerRef = useRef<HTMLDivElement>(null);
  const lastScrollTop = useRef(0);
  const scrollSetupTimeoutRef = useRef<NodeJS.Timeout | null>(null);
  const scrollSetupRafRef = useRef<number | null>(null);
  const selectionAnchorRef = useRef<string | null>(null);
  const contextMenu = useDropdownMenu<{ commitHashes: string[] }>();
  const [selectedCommitHashes, setSelectedCommitHashes] = useState<Set<string>>(new Set());
  const [isMutatingHistory, setIsMutatingHistory] = useState(false);
  const [historySearchQuery, setHistorySearchQuery] = useState("");
  const [historySearchScope, setHistorySearchScope] = useState<HistorySearchScope>("all");

  const filteredCommits = useMemo(() => {
    const query = historySearchQuery.trim();
    if (!query) return commits;

    return commits.filter((commit) =>
      matchesSearchQuery(query, getCommitSearchFields(commit, historySearchScope)),
    );
  }, [commits, historySearchQuery, historySearchScope]);

  const commitSyncStateByHash = useMemo(() => {
    const syncState = new Map<string, "local" | "pushed">();
    commits.forEach((commit, index) => {
      syncState.set(commit.hash, index < ahead ? "local" : "pushed");
    });
    return syncState;
  }, [ahead, commits]);

  useEffect(() => {
    const availableHashes = new Set(commits.map((commit) => commit.hash));
    setSelectedCommitHashes((current) => {
      const next = new Set([...current].filter((hash) => availableHashes.has(hash)));
      return next.size === current.size ? current : next;
    });
    if (selectionAnchorRef.current && !availableHashes.has(selectionAnchorRef.current)) {
      selectionAnchorRef.current = null;
    }
  }, [commits]);

  const handleCommitSelect = useCallback(
    (event: React.MouseEvent, commit: GitCommit) => {
      const result = updateGitHistorySelection(
        filteredCommits.map((candidate) => candidate.hash),
        selectedCommitHashes,
        commit.hash,
        selectionAnchorRef.current,
        {
          additive: event.ctrlKey || event.metaKey,
          range: event.shiftKey,
        },
      );
      setSelectedCommitHashes(result.selected);
      selectionAnchorRef.current = result.anchor;
      if (!(event.ctrlKey || event.metaKey || event.shiftKey)) {
        onViewCommitDiff?.(commit.hash);
      }
    },
    [filteredCommits, onViewCommitDiff, selectedCommitHashes],
  );

  const handleCommitContextMenu = useCallback(
    (event: React.MouseEvent, commit: GitCommit) => {
      const next = resolveGitHistoryContextSelection(selectedCommitHashes, commit.hash);
      setSelectedCommitHashes(next);
      if (!selectedCommitHashes.has(commit.hash)) {
        selectionAnchorRef.current = commit.hash;
      }
      contextMenu.open(event, { commitHashes: [...next] });
    },
    [contextMenu, selectedCommitHashes],
  );

  const contextMenuCommits = useMemo(
    () => selectedCommitsInHistoryOrder(commits, new Set(contextMenu.data?.commitHashes ?? [])),
    [commits, contextMenu.data],
  );
  const contextSelection = useMemo(
    () => new Set(contextMenuCommits.map((commit) => commit.hash)),
    [contextMenuCommits],
  );
  const contextSelectionIsContiguous = isContiguousGitHistorySelection(commits, contextSelection);

  const runHistoryAction = async (action: () => Promise<void>) => {
    setIsMutatingHistory(true);
    try {
      await action();
      setSelectedCommitHashes(new Set());
      selectionAnchorRef.current = null;
    } catch (error) {
      const message =
        error instanceof Error
          ? error.message
          : typeof error === "object" && error && "message" in error
            ? String(error.message)
            : String(error);
      toast.error(message || t("git.historyMutationFailed"));
    } finally {
      setIsMutatingHistory(false);
    }
  };

  const handleEditCommitMessage = async (commit: GitCommit) => {
    if (!repoPath) return;
    const message = await showPromptDialog(
      t("git.editCommitMessagePrompt", { hash: commit.shortHash }),
      {
        title: t("git.editCommitMessage"),
        confirmLabel: t("git.saveCommitMessage"),
        defaultValue: commit.message,
      },
    );
    if (!message?.trim() || message.trim() === commit.message) return;
    await runHistoryAction(() => editCommitMessage(repoPath, commit.hash, message.trim()));
  };

  const handleDeleteCommit = async (commit: GitCommit) => {
    if (
      !repoPath ||
      !(await showConfirmDialog(
        t("git.deleteCommitConfirm", { hash: commit.shortHash, message: commit.message }),
        {
          title: t("git.deleteCommit"),
          confirmLabel: t("git.deleteCommit"),
        },
      ))
    ) {
      return;
    }
    await runHistoryAction(() => deleteCommit(repoPath, commit.hash));
  };

  const handleSquashCommits = async () => {
    if (!repoPath || !contextSelectionIsContiguous || contextMenuCommits.length < 2) return;
    const oldestCommit = contextMenuCommits[contextMenuCommits.length - 1];
    const message = await showPromptDialog(
      t("git.squashCommitsPrompt", { count: contextMenuCommits.length }),
      {
        title: t("git.squashCommits"),
        confirmLabel: t("git.squash"),
        defaultValue: oldestCommit.message,
      },
    );
    if (!message?.trim()) return;
    await runHistoryAction(() =>
      squashCommits(
        repoPath,
        contextMenuCommits.map((commit) => commit.hash),
        message.trim(),
      ),
    );
  };

  const handleResetToCommit = async (commit: GitCommit) => {
    if (!repoPath) return;
    const mode = await showChoiceDialog<GitResetMode>(
      t("git.resetToCommitPrompt", { hash: commit.shortHash }),
      {
        title: t("git.resetToCommit"),
        choices: [
          { value: "soft", label: t("git.resetSoft") },
          { value: "mixed", label: t("git.resetMixed"), variant: "accent" },
          { value: "hard", label: t("git.resetHard"), variant: "danger" },
        ],
      },
    );
    if (!mode) return;
    await runHistoryAction(() => resetToCommit(repoPath, commit.hash, mode));
  };

  const handleCherryPickCommit = async (commit: GitCommit) => {
    if (
      !repoPath ||
      !(await showConfirmDialog(
        t("git.cherryPickCommitConfirm", { hash: commit.shortHash, message: commit.message }),
        {
          title: t("git.cherryPickCommit"),
          confirmLabel: t("git.cherryPickCommit"),
        },
      ))
    ) {
      return;
    }
    await runHistoryAction(() => cherryPickCommit(repoPath, commit.hash));
  };

  const contextMenuItems: MenuItem[] = (() => {
    if (contextMenuCommits.length > 1) {
      return [
        {
          id: "squash-commits",
          label: t("git.squashCommits"),
          icon: <Squash />,
          disabled: isMutatingHistory || !contextSelectionIsContiguous,
          onClick: () => void handleSquashCommits(),
        },
      ];
    }

    const commit = contextMenuCommits[0];
    if (!commit) return [];
    return [
      {
        id: "edit-commit-message",
        label: t("git.editCommitMessage"),
        icon: <Edit />,
        disabled: isMutatingHistory,
        onClick: () => void handleEditCommitMessage(commit),
      },
      {
        id: "delete-commit",
        label: t("git.deleteCommit"),
        icon: <Trash />,
        className: "text-destructive",
        disabled: isMutatingHistory,
        onClick: () => void handleDeleteCommit(commit),
      },
      {
        id: "reset-to-commit",
        label: t("git.resetToCommit"),
        icon: <Reset />,
        disabled: isMutatingHistory,
        onClick: () => void handleResetToCommit(commit),
      },
      {
        id: "cherry-pick-commit",
        label: t("git.cherryPickCommit"),
        icon: <CherryPick />,
        disabled: isMutatingHistory || commits[0]?.hash === commit.hash,
        onClick: () => void handleCherryPickCommit(commit),
      },
    ];
  })();

  const hasHistoryRows = commits.length > 0;
  const hasHistoryFilter = historySearchScope !== "all";

  useEffect(() => {
    if (!repoPath) return;

    let scrollHandler: (() => void) | null = null;
    let isListenerAttached = false;

    const handleScroll = () => {
      const container = scrollContainerRef.current;
      if (!container) return;

      const { scrollTop, scrollHeight, clientHeight } = container;
      const isScrollingDown = scrollTop > lastScrollTop.current;
      lastScrollTop.current = scrollTop;

      const scrollPercent = (scrollTop + clientHeight) / scrollHeight;

      if (isScrollingDown && scrollPercent >= 0.8) {
        if (hasMoreCommits && !isLoadingMoreCommits) {
          actions.loadMoreCommits(repoPath);
        }
      }
    };

    const setupScrollListener = () => {
      const container = scrollContainerRef.current;
      if (!container || isListenerAttached) return false;

      if (container.scrollHeight > container.clientHeight && hasMoreCommits) {
        container.addEventListener("scroll", handleScroll);
        isListenerAttached = true;
        scrollHandler = handleScroll;
        return true;
      }
      return false;
    };

    const removeScrollListener = () => {
      const container = scrollContainerRef.current;
      if (container && isListenerAttached && scrollHandler) {
        container.removeEventListener("scroll", scrollHandler);
        isListenerAttached = false;
        scrollHandler = null;
      }
    };

    if (commits.length === 0) {
      lastScrollTop.current = 0;
    }

    if (!setupScrollListener()) {
      if (scrollSetupRafRef.current) {
        cancelAnimationFrame(scrollSetupRafRef.current);
      }
      scrollSetupRafRef.current = requestAnimationFrame(() => {
        if (!setupScrollListener()) {
          if (scrollSetupTimeoutRef.current) {
            clearTimeout(scrollSetupTimeoutRef.current);
          }
          scrollSetupTimeoutRef.current = setTimeout(() => {
            setupScrollListener();
            scrollSetupTimeoutRef.current = null;
          }, 100);
        }
        scrollSetupRafRef.current = null;
      });
    }

    return () => {
      if (scrollSetupRafRef.current) {
        cancelAnimationFrame(scrollSetupRafRef.current);
        scrollSetupRafRef.current = null;
      }
      if (scrollSetupTimeoutRef.current) {
        clearTimeout(scrollSetupTimeoutRef.current);
        scrollSetupTimeoutRef.current = null;
      }
      removeScrollListener();
    };
  }, [commits.length, hasMoreCommits, isLoadingMoreCommits, repoPath, actions]);

  return (
    <div className="flex h-full min-h-0 flex-1 flex-col overflow-hidden select-none">
      <SidebarHeader className="px-3">
        <SidebarSearchPopover
          value={historySearchQuery}
          onChange={setHistorySearchQuery}
          placeholder={t("git.historySearch")}
          aria-label={t("git.historySearch")}
        />
        <DropdownMenu>
          <DropdownMenuTrigger
            render={
              <SidebarHeaderIconButton
                active={hasHistoryFilter}
                tooltip={t("git.historyFilter")}
                tooltipSide="bottom"
                aria-label={t("git.historyFilter")}
              />
            }
          >
            <Funnel />
          </DropdownMenuTrigger>
          <DropdownMenuContent>
            <DropdownMenuRadioGroup
              value={historySearchScope}
              onValueChange={(scope) => setHistorySearchScope(scope as HistorySearchScope)}
            >
              {(Object.keys(HISTORY_SEARCH_SCOPE_KEYS) as HistorySearchScope[]).map((scope) => (
                <DropdownMenuRadioItem key={scope} value={scope} closeOnClick>
                  {t(HISTORY_SEARCH_SCOPE_KEYS[scope])}
                </DropdownMenuRadioItem>
              ))}
            </DropdownMenuRadioGroup>
          </DropdownMenuContent>
        </DropdownMenu>
      </SidebarHeader>

      {(ahead > 0 || behind > 0) && (
        <div className="space-y-1 px-2 pb-1">
          {ahead > 0 ? (
            <div className="ui-text-sm text-subtle-foreground">
              <span className="text-primary">{ahead}</span>{" "}
              {t("git.localCommitsNotPushed", { count: ahead, plural: ahead !== 1 ? "s" : "" })}
            </div>
          ) : null}
          {behind > 0 ? (
            <div className="ui-text-sm text-subtle-foreground">
              <span className="text-primary">{behind}</span>{" "}
              {t("git.remoteCommitsNotPulled", { count: behind, plural: behind !== 1 ? "s" : "" })}
            </div>
          ) : null}
        </div>
      )}

      <div
        className="scrollbar-none relative min-h-0 flex-1 overflow-y-scroll bg-transparent pb-1"
        ref={scrollContainerRef}
      >
        {!hasHistoryRows ? (
          <EmptyState message={t("git.historyNoCommits")} />
        ) : filteredCommits.length === 0 ? (
          <EmptyState message={t("git.historyNoMatch")} />
        ) : (
          <>
            {filteredCommits.map((commit) => (
              <CommitItem
                key={commit.hash}
                commit={commit}
                onSelect={handleCommitSelect}
                onContextMenu={handleCommitContextMenu}
                isSelected={selectedCommitHashes.has(commit.hash)}
                syncState={commitSyncStateByHash.get(commit.hash) ?? "pushed"}
                repoPath={repoPath}
              />
            ))}

            {isLoadingMoreCommits && (
              <div className="flex justify-center px-3 py-1.5 text-subtle-foreground">
                <Spinner label={t("git.log.loadingCommits")} showLabel compact />
              </div>
            )}

            {!hasMoreCommits && commits.length > 0 && (
              <div className="ui-text-sm px-3 py-1.5 text-center text-subtle-foreground">
                {t("git.historyEnd")}
              </div>
            )}
          </>
        )}
      </div>

      <Dropdown
        isOpen={contextMenu.isOpen}
        point={contextMenu.position}
        items={contextMenuItems}
        onClose={contextMenu.close}
      />
    </div>
  );
};

export default GitCommitHistory;
