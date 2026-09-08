import {
  ArrowsInLineVerticalIcon,
  ArrowClockwiseIcon,
  CaretDownIcon,
  CaretRightIcon,
  ChevronExpandYIcon,
  CheckIcon,
  FolderIcon,
  FolderPlusIcon,
  FunnelIcon as Filter,
  GitBranchIcon,
  GitDiffIcon,
  GitMergeIcon,
  NetworkIcon,
  PencilIcon,
  PlusIcon,
  StarIcon,
  TagIcon,
  TrashIcon,
  UploadIcon,
} from "@/ui/icons";
import { useLayoutEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { cn } from "@/utils/cn";
import { useTranslation } from "@/i18n/locale-provider";
import { HoverCard, HoverCardContent, HoverCardTrigger } from "@/ui/hover-card";
import { bindScrollContainerWheel } from "@/ui/scroll-container-wheel";
import Tooltip from "@/ui/tooltip";
import { normalizeRepositoryPath } from "../../api/git-repo-api";
import {
  ContextMenu,
  ContextMenuContent,
  ContextMenuItem,
  ContextMenuSeparator,
  ContextMenuSub,
  ContextMenuSubContent,
  ContextMenuSubTrigger,
  ContextMenuTrigger,
} from "@/ui/context-menu";
import { useGitLogPreferencesStore } from "../../stores/git-log-preferences.store";
import type { GitReference, GitReferenceKind } from "../../types/git.types";
import {
  getGitReferenceActions,
  getGitReferenceToolbarState,
  isGitReferencePullAction,
  type GitReferenceAction,
} from "../../utils/git-reference-actions";
import {
  buildGitReferenceTree,
  collectGitReferenceGroupIds,
  countGitReferencesByKind,
  filterGitLogReferences,
  type GitReferenceTreeNode,
} from "../../utils/git-reference-tree";
import { getVisibleGitReferenceToolbarActionCount } from "../../utils/git-reference-toolbar-layout";
import { GitTrackingCounts } from "../git-tracking-counts";
import { GitFetchIcon, GitUpdateIcon, LocateHeadIcon } from "./git-reference-toolbar-icons";

const SECTION_KEYS: Array<{ kind: GitReferenceKind; titleKey: string }> = [
  { kind: "local", titleKey: "git.log.local" },
  { kind: "remote", titleKey: "git.log.remote" },
  { kind: "tag", titleKey: "git.log.tags" },
];
const EMPTY_MARKED_REFERENCE_IDS: string[] = [];

function ReferenceIcon({
  kind,
  isCurrent = false,
  isMarked = false,
}: {
  kind: GitReferenceKind;
  isCurrent?: boolean;
  isMarked?: boolean;
}) {
  if (isCurrent) return <CheckIcon className="size-3.5 text-amber-400" />;
  if (isMarked) return <StarIcon className="size-3.5 fill-amber-400 text-amber-400" />;
  if (kind === "tag") return <TagIcon className="size-3.5 text-amber-400" />;
  if (kind === "remote") return <NetworkIcon className="size-3.5 text-subtle-foreground" />;
  return <GitBranchIcon className="size-3.5 text-subtle-foreground" />;
}

interface GitReferenceTreeProps {
  repoPath: string;
  references: GitReference[];
  selectedReference: GitReference | null;
  isMutating?: boolean;
  isPullLocked?: boolean;
  onSelect: (reference: GitReference | null) => void;
  onReferenceAction: (action: GitReferenceAction, reference: GitReference) => void;
  onSetUpstream: (branch: GitReference, upstream: GitReference | null) => void;
  onManageRemotes: () => void;
  onFetch: () => void;
  onNavigateToHead: () => void;
  canNavigateToHead?: boolean;
}

function ActionIcon({ action }: { action: GitReferenceAction }) {
  if (action === "createBranch") return <PlusIcon />;
  if (action === "createWorktree") return <FolderPlusIcon />;
  if (action === "compareWithCurrent" || action === "diffWithWorkingTree") {
    return <GitDiffIcon />;
  }
  if (action === "mergeIntoCurrent") return <GitMergeIcon />;
  if (
    action === "update" ||
    action === "checkoutAndUpdate" ||
    action === "pullRebaseIntoCurrent" ||
    action === "pullMergeIntoCurrent"
  ) {
    return <ArrowClockwiseIcon />;
  }
  if (action === "push") return <UploadIcon />;
  if (action === "rename") return <PencilIcon />;
  if (action === "deleteLocal" || action === "deleteRemote") return <TrashIcon />;
  return <GitBranchIcon />;
}

function ReferenceToolbarButton({
  label,
  disabled = false,
  active = false,
  overflow = false,
  onClick,
  children,
}: {
  label: string;
  disabled?: boolean;
  active?: boolean;
  overflow?: boolean;
  onClick: () => void;
  children: ReactNode;
}) {
  return (
    <Tooltip
      content={label}
      side={overflow ? "top" : "right"}
      triggerClassName={cn("shrink-0 justify-center", !overflow && "w-full")}
    >
      <button
        type="button"
        aria-label={label}
        aria-pressed={active ? true : undefined}
        disabled={disabled}
        onClick={onClick}
        className={cn(
          "flex size-8 shrink-0 items-center justify-center rounded-sm text-subtle-foreground transition-colors hover:bg-accent hover:text-foreground disabled:pointer-events-none disabled:opacity-30 [&_svg]:size-4",
          active && "bg-accent/70 text-amber-400",
        )}
      >
        {children}
      </button>
    </Tooltip>
  );
}

type ReferenceToolbarSection = "primary" | "secondary" | "footer";

interface ReferenceToolbarAction {
  id: string;
  section: ReferenceToolbarSection;
  label: string;
  disabled: boolean;
  active?: boolean;
  onClick: () => void;
  icon: ReactNode;
}

function GitReferenceToolbar({
  selectedReference,
  currentReference,
  isMutating,
  isPullLocked,
  isMarked,
  hasReferences,
  onReferenceAction,
  onFetch,
  onToggleMark,
  onExpandAll,
  onCollapseAll,
  showMyBranchesOnly,
  hasMyBranches,
  onToggleMyBranches,
  onNavigateToHead,
  canNavigateToHead,
}: {
  selectedReference: GitReference | null;
  currentReference: GitReference | null;
  isMutating: boolean;
  isPullLocked: boolean;
  isMarked: boolean;
  hasReferences: boolean;
  onReferenceAction: (action: GitReferenceAction, reference: GitReference) => void;
  onFetch: () => void;
  onToggleMark: () => void;
  onExpandAll: () => void;
  onCollapseAll: () => void;
  showMyBranchesOnly: boolean;
  hasMyBranches: boolean;
  onToggleMyBranches: () => void;
  onNavigateToHead: () => void;
  canNavigateToHead: boolean;
}) {
  const { t } = useTranslation();
  const state = getGitReferenceToolbarState(selectedReference, currentReference, isMutating);
  const branchSource = selectedReference ?? currentReference;
  const toolbarRef = useRef<HTMLDivElement>(null);
  const actions: ReferenceToolbarAction[] = [
    {
      id: "new-branch",
      section: "primary",
      label: t("git.log.toolbar.newBranch"),
      disabled: !state.canCreateBranch,
      onClick: () => branchSource && onReferenceAction("createBranch", branchSource),
      icon: <PlusIcon />,
    },
    {
      id: "update-selected",
      section: "primary",
      label: t("git.log.toolbar.updateSelected"),
      disabled:
        !state.canUpdateSelected ||
        Boolean(
          isPullLocked &&
            selectedReference &&
            isGitReferencePullAction("update", selectedReference),
        ),
      onClick: () => selectedReference && onReferenceAction("update", selectedReference),
      icon: <GitUpdateIcon />,
    },
    {
      id: "delete-branch",
      section: "primary",
      label: t("git.log.toolbar.deleteBranch"),
      disabled: !state.canDeleteBranch,
      onClick: () => selectedReference && onReferenceAction("deleteLocal", selectedReference),
      icon: <TrashIcon />,
    },
    {
      id: "compare-with-current",
      section: "primary",
      label: t("git.log.toolbar.compareWithCurrent"),
      disabled: !state.canCompareWithCurrent,
      onClick: () =>
        selectedReference && onReferenceAction("compareWithCurrent", selectedReference),
      icon: <GitDiffIcon />,
    },
    {
      id: "fetch",
      section: "secondary",
      label: t("git.log.toolbar.fetch"),
      disabled: !state.canFetch,
      onClick: onFetch,
      icon: <GitFetchIcon />,
    },
    {
      id: "toggle-mark",
      section: "secondary",
      label: t(isMarked ? "git.log.toolbar.unmark" : "git.log.toolbar.mark"),
      disabled: !state.canToggleMark,
      active: isMarked,
      onClick: onToggleMark,
      icon: <StarIcon className={cn(isMarked && "fill-current")} />,
    },
    {
      id: "go-to-head",
      section: "secondary",
      label: t("git.log.toolbar.goToHead"),
      disabled: !canNavigateToHead,
      onClick: onNavigateToHead,
      icon: <LocateHeadIcon />,
    },
    {
      id: "toggle-my-branches",
      section: "secondary",
      label: t(
        showMyBranchesOnly
          ? "git.log.toolbar.showAllBranches"
          : "git.log.toolbar.showMyBranches",
      ),
      disabled: !hasMyBranches && !showMyBranchesOnly,
      active: showMyBranchesOnly,
      onClick: onToggleMyBranches,
      icon: <Filter />,
    },
    {
      id: "expand-all",
      section: "footer",
      label: t("git.expandAll"),
      disabled: !hasReferences,
      onClick: onExpandAll,
      icon: <ChevronExpandYIcon />,
    },
    {
      id: "collapse-all",
      section: "footer",
      label: t("git.collapseAll"),
      disabled: !hasReferences,
      onClick: onCollapseAll,
      icon: <ArrowsInLineVerticalIcon />,
    },
  ];
  const [visibleActionCount, setVisibleActionCount] = useState(actions.length);

  useLayoutEffect(() => {
    const element = toolbarRef.current;
    if (!element) return;

    const updateVisibleActionCount = () => {
      const height = element.clientHeight;
      if (height <= 0) return;
      const nextCount = getVisibleGitReferenceToolbarActionCount(height, actions.length);
      setVisibleActionCount((currentCount) =>
        currentCount === nextCount ? currentCount : nextCount,
      );
    };

    updateVisibleActionCount();
    const observer = new ResizeObserver(updateVisibleActionCount);
    observer.observe(element);
    return () => observer.disconnect();
  }, [actions.length]);

  const isOverflowing = visibleActionCount < actions.length;
  const visibleActions = isOverflowing ? actions.slice(0, visibleActionCount) : actions;
  const overflowActions = isOverflowing ? actions.slice(visibleActionCount) : [];
  const renderAction = (action: ReferenceToolbarAction, overflow = false) => (
    <ReferenceToolbarButton
      key={action.id}
      label={action.label}
      disabled={action.disabled}
      active={action.active}
      overflow={overflow}
      onClick={action.onClick}
    >
      {action.icon}
    </ReferenceToolbarButton>
  );

  if (!isOverflowing) {
    const primaryActions = visibleActions.filter((action) => action.section === "primary");
    const secondaryActions = visibleActions.filter((action) => action.section === "secondary");
    const footerActions = visibleActions.filter((action) => action.section === "footer");

    return (
      <div
        ref={toolbarRef}
        className="flex h-full min-h-0 w-9 shrink-0 flex-col items-center overflow-hidden border-border border-r bg-surface/60 py-1"
      >
        {primaryActions.map((action) => renderAction(action))}
        <div className="my-1 h-px w-5 shrink-0 bg-border" />
        {secondaryActions.map((action) => renderAction(action))}
        <div className="mt-auto" />
        {footerActions.map((action) => renderAction(action))}
      </div>
    );
  }

  return (
    <div
      ref={toolbarRef}
      className="flex h-full min-h-0 w-9 shrink-0 flex-col items-center overflow-hidden border-border border-r bg-surface/60 py-1"
    >
      {visibleActions.map((action) => renderAction(action))}
      <div className="mt-auto" />
      <HoverCard>
        <HoverCardTrigger
          delay={120}
          closeDelay={160}
          render={
            <button
              type="button"
              aria-label={t("git.log.toolbar.moreActions")}
              className="flex size-8 shrink-0 items-center justify-center rounded-sm text-subtle-foreground transition-colors hover:bg-accent hover:text-foreground focus-visible:bg-accent focus-visible:text-foreground focus-visible:outline-none [&_svg]:size-4"
            >
              <CaretRightIcon />
            </button>
          }
        />
        <HoverCardContent
          side="right"
          align="end"
          sideOffset={2}
          className="flex w-auto items-center gap-0.5 rounded-md p-0.5"
        >
          {overflowActions.map((action, index) => (
            <div key={action.id} className="flex shrink-0 items-center">
              {index > 0 && overflowActions[index - 1]?.section !== action.section ? (
                <div className="mx-1 h-5 w-px shrink-0 bg-border" />
              ) : null}
              {renderAction(action, true)}
            </div>
          ))}
        </HoverCardContent>
      </HoverCard>
    </div>
  );
}

function ReferenceActionMenu({
  reference,
  currentReference,
  remoteReferences,
  isMutating,
  isPullLocked,
  onAction,
  onSetUpstream,
}: {
  reference: GitReference;
  currentReference: GitReference | null;
  remoteReferences: GitReference[];
  isMutating: boolean;
  isPullLocked: boolean;
  onAction: (action: GitReferenceAction, reference: GitReference) => void;
  onSetUpstream: (branch: GitReference, upstream: GitReference | null) => void;
}) {
  const { t } = useTranslation();
  const actions = getGitReferenceActions(reference);
  const currentName = currentReference?.shortName ?? "HEAD";
  const groups: GitReferenceAction[][] = reference.isCurrent
    ? [
        ["createBranch"],
        ["diffWithWorkingTree", "createWorktree"],
        ["update", "push", "tracking"],
        ["rename"],
      ]
    : reference.kind === "remote"
      ? [
          ["checkout", "createBranch", "checkoutAndRebase"],
          ["compareWithCurrent", "diffWithWorkingTree"],
          ["rebaseCurrentOnto", "mergeIntoCurrent"],
          ["createWorktree"],
          ["pullRebaseIntoCurrent", "pullMergeIntoCurrent"],
          ["deleteRemote"],
        ]
      : [
          ["checkout", "createBranch", "checkoutAndRebase", "checkoutAndUpdate"],
          ["compareWithCurrent", "diffWithWorkingTree"],
          ["rebaseCurrentOnto", "mergeIntoCurrent"],
          ["createWorktree"],
          ["update", "push"],
          ["rename", "deleteLocal"],
        ];
  const labels: Record<GitReferenceAction, string> = {
    checkout: t("git.checkout"),
    createBranch: t("git.log.newBranchFrom", { branch: reference.shortName }),
    checkoutAndRebase: t("git.log.checkoutAndRebaseOnto", { branch: currentName }),
    checkoutAndUpdate: t("git.log.checkoutAndUpdate"),
    compareWithCurrent: t("git.log.compareWithCurrent", { branch: currentName }),
    diffWithWorkingTree: t("git.log.showDiffWithWorkingTree"),
    rebaseCurrentOnto: t("git.log.rebaseCurrentOnto", {
      current: currentName,
      branch: reference.shortName,
    }),
    mergeIntoCurrent: t("git.log.mergeIntoCurrent", {
      branch: reference.shortName,
      current: currentName,
    }),
    pullRebaseIntoCurrent: t("git.log.pullRebaseIntoCurrent", { branch: currentName }),
    pullMergeIntoCurrent: t("git.log.pullMergeIntoCurrent", { branch: currentName }),
    createWorktree: t("git.log.newWorktreeFrom", { branch: reference.shortName }),
    update: t("git.log.updateBranch"),
    push: t("git.push"),
    tracking: t("git.log.trackingBranch"),
    rename: t("git.log.renameBranch"),
    deleteLocal: t("git.deleteBranch"),
    deleteRemote: t("git.log.deleteRemoteBranch"),
  };

  return (
    <ContextMenuContent className="min-w-72">
      {groups.map((group, groupIndex) => {
        const visibleActions = group.filter((action) => actions.includes(action));
        if (visibleActions.length === 0) return null;
        return (
          <div key={groupIndex}>
            {groupIndex > 0 ? <ContextMenuSeparator /> : null}
            {visibleActions.map((action) => {
              if (action === "tracking") {
                return (
                  <ContextMenuSub key={action}>
                    <ContextMenuSubTrigger disabled={isMutating}>
                      <NetworkIcon />
                      {labels[action]}
                    </ContextMenuSubTrigger>
                    <ContextMenuSubContent className="min-w-72">
                      {reference.upstreamShortName ? (
                        <>
                          <ContextMenuItem disabled>
                            <CheckIcon className="text-primary" />
                            {reference.upstreamShortName}
                          </ContextMenuItem>
                          <ContextMenuItem
                            disabled={isMutating}
                            onClick={() => onSetUpstream(reference, null)}
                          >
                            {t("git.log.stopTrackingBranch")}
                          </ContextMenuItem>
                          <ContextMenuSeparator />
                        </>
                      ) : null}
                      {remoteReferences.map((remoteReference) => (
                        <ContextMenuItem
                          key={remoteReference.fullName}
                          disabled={
                            isMutating ||
                            remoteReference.shortName === reference.upstreamShortName
                          }
                          onClick={() => onSetUpstream(reference, remoteReference)}
                        >
                          <NetworkIcon />
                          {remoteReference.shortName}
                        </ContextMenuItem>
                      ))}
                      {remoteReferences.length === 0 ? (
                        <ContextMenuItem disabled>{t("git.log.noRemoteBranches")}</ContextMenuItem>
                      ) : null}
                    </ContextMenuSubContent>
                  </ContextMenuSub>
                );
              }
              const destructive = action === "deleteLocal" || action === "deleteRemote";
              const disabled =
                isMutating ||
                (isPullLocked && isGitReferencePullAction(action, reference)) ||
                (action === "checkoutAndUpdate" && !reference.upstreamShortName) ||
                (action === "update" &&
                  !(
                    reference.isCurrent ||
                    (reference.upstreamShortName && (reference.behind ?? 0) > 0)
                  ));
              return (
                <ContextMenuItem
                  key={action}
                  disabled={disabled}
                  variant={destructive ? "destructive" : "default"}
                  onClick={() => onAction(action, reference)}
                >
                  <ActionIcon action={action} />
                  {labels[action]}
                </ContextMenuItem>
              );
            })}
          </div>
        );
      })}
    </ContextMenuContent>
  );
}

function ReferenceNode({
  node,
  kind,
  depth,
  selectedFullName,
  collapsedGroups,
  currentReference,
  remoteReferences,
  markedReferenceFullNames,
  isMutating,
  isPullLocked,
  onToggleGroup,
  onSelect,
  onReferenceAction,
  onSetUpstream,
}: {
  node: GitReferenceTreeNode;
  kind: GitReferenceKind;
  depth: number;
  selectedFullName?: string;
  collapsedGroups: Set<string>;
  currentReference: GitReference | null;
  remoteReferences: GitReference[];
  markedReferenceFullNames: Set<string>;
  isMutating: boolean;
  isPullLocked: boolean;
  onToggleGroup: (id: string) => void;
  onSelect: (reference: GitReference) => void;
  onReferenceAction: (action: GitReferenceAction, reference: GitReference) => void;
  onSetUpstream: (branch: GitReference, upstream: GitReference | null) => void;
}) {
  const { t } = useTranslation();
  const isGroup = node.children.length > 0;
  const isCollapsed = collapsedGroups.has(node.id);
  const left = 10 + depth * 14;

  const row = (
    <div
      className={cn(
        "flex h-6 w-full min-w-0 items-center gap-1.5 rounded px-1.5 text-left hover:bg-accent/80",
        node.reference?.fullName === selectedFullName && "bg-accent text-accent-foreground",
        node.reference?.isCurrent && "font-semibold text-amber-300",
      )}
      style={{ paddingLeft: left }}
      onContextMenu={() => {
        if (node.reference) onSelect(node.reference);
      }}
    >
      {isGroup ? (
        <button
          type="button"
          className="flex size-3.5 shrink-0 items-center justify-center"
          onClick={() => onToggleGroup(node.id)}
          aria-label={t(isCollapsed ? "git.log.expand" : "git.log.collapse", { name: node.path })}
        >
          {isCollapsed ? <CaretRightIcon /> : <CaretDownIcon />}
        </button>
      ) : (
        <span className="size-3.5 shrink-0" />
      )}
      <button
        type="button"
        className="flex min-w-0 flex-1 items-center gap-1.5 text-left"
        onClick={() => {
          if (node.reference) onSelect(node.reference);
          else if (isGroup) onToggleGroup(node.id);
        }}
        title={node.reference?.shortName ?? node.path}
      >
        {isGroup && !node.reference ? (
          <FolderIcon className="size-3.5 shrink-0 text-subtle-foreground" />
        ) : (
          <ReferenceIcon
            kind={kind}
            isCurrent={node.reference?.isCurrent}
            isMarked={
              node.reference ? markedReferenceFullNames.has(node.reference.fullName) : false
            }
          />
        )}
        <span className="truncate">{node.name}</span>
        {node.reference ? (
          <span className="ml-auto flex shrink-0 items-center gap-1.5">
            {node.reference.upstreamShortName ? (
              <GitTrackingCounts
                ahead={node.reference.ahead}
                behind={node.reference.behind}
                aheadLabel={t("git.aheadOfRemote", { count: node.reference.ahead ?? 0 })}
                behindLabel={t("git.behindRemote", { count: node.reference.behind ?? 0 })}
              />
            ) : null}
            {node.reference.isCurrent ? (
              <span className="shrink-0 rounded bg-amber-400/12 px-1 text-[10px] font-medium text-amber-300">
                {t("git.current")}
              </span>
            ) : null}
          </span>
        ) : null}
      </button>
    </div>
  );
  const actions = node.reference ? getGitReferenceActions(node.reference) : [];

  return (
    <>
      <ContextMenu>
        <ContextMenuTrigger>{row}</ContextMenuTrigger>
        {node.reference && actions.length > 0 ? (
          <ReferenceActionMenu
            reference={node.reference}
            currentReference={currentReference}
            remoteReferences={remoteReferences}
            isMutating={isMutating}
            isPullLocked={isPullLocked}
            onAction={onReferenceAction}
            onSetUpstream={onSetUpstream}
          />
        ) : (
          <ContextMenuContent>
            <ContextMenuItem disabled>{t("ui.noActionsHere")}</ContextMenuItem>
          </ContextMenuContent>
        )}
      </ContextMenu>
      {!isCollapsed &&
        node.children.map((child) => (
          <ReferenceNode
            key={child.id}
            node={child}
            kind={kind}
            depth={depth + 1}
            selectedFullName={selectedFullName}
            collapsedGroups={collapsedGroups}
            currentReference={currentReference}
            remoteReferences={remoteReferences}
            markedReferenceFullNames={markedReferenceFullNames}
            isMutating={isMutating}
            isPullLocked={isPullLocked}
            onToggleGroup={onToggleGroup}
            onSelect={onSelect}
            onReferenceAction={onReferenceAction}
            onSetUpstream={onSetUpstream}
          />
        ))}
    </>
  );
}

export function GitReferenceTree({
  repoPath,
  references,
  selectedReference,
  isMutating = false,
  isPullLocked = false,
  onSelect,
  onReferenceAction,
  onSetUpstream,
  onManageRemotes,
  onFetch,
  onNavigateToHead,
  canNavigateToHead = false,
}: GitReferenceTreeProps) {
  const { t } = useTranslation();
  const collapsedSectionIds = useGitLogPreferencesStore.use.collapsedReferenceSections();
  const collapsedGroupIds = useGitLogPreferencesStore.use.collapsedReferenceGroups();
  const markedReferenceIdsByRepository =
    useGitLogPreferencesStore.use.markedReferenceFullNamesByRepository();
  const showMyBranchesOnly = useGitLogPreferencesStore.use.showMyBranchesOnly();
  const {
    toggleReferenceSection,
    toggleReferenceGroup,
    setReferenceExpansion,
    toggleMarkedReference,
    setShowMyBranchesOnly,
  } = useGitLogPreferencesStore.use.actions();
  const repositoryPreferenceKey = normalizeRepositoryPath(repoPath);
  const markedReferenceIds =
    markedReferenceIdsByRepository[repositoryPreferenceKey] ?? EMPTY_MARKED_REFERENCE_IDS;
  const scrollRef = useRef<HTMLDivElement>(null);
  const collapsedSections = useMemo(() => new Set(collapsedSectionIds), [collapsedSectionIds]);
  const collapsedGroups = useMemo(() => new Set(collapsedGroupIds), [collapsedGroupIds]);
  const markedLocalReferenceFullNames = useMemo(
    () => {
      const localReferenceFullNames = new Set(
        references
          .filter((reference) => reference.kind === "local")
          .map((reference) => reference.fullName),
      );
      return new Set(
        markedReferenceIds.filter((fullName) => localReferenceFullNames.has(fullName)),
      );
    },
    [markedReferenceIds, references],
  );
  const visibleReferences = useMemo(
    () =>
      filterGitLogReferences(
        references,
        markedLocalReferenceFullNames,
        showMyBranchesOnly,
        selectedReference?.fullName,
      ),
    [markedLocalReferenceFullNames, references, selectedReference?.fullName, showMyBranchesOnly],
  );
  const hasMyBranches = useMemo(
    () =>
      references.some(
        (reference) =>
          reference.kind === "local" &&
          (reference.isCurrent || markedLocalReferenceFullNames.has(reference.fullName)),
      ),
    [markedLocalReferenceFullNames, references],
  );
  const currentReference = references.find((reference) => reference.isCurrent) ?? null;
  const remoteReferences = useMemo(
    () => references.filter((reference) => reference.kind === "remote"),
    [references],
  );
  const trees = useMemo(
    () =>
      new Map(
        SECTION_KEYS.map(({ kind }) => [
          kind,
          buildGitReferenceTree(
            visibleReferences,
            kind,
            kind === "local" ? markedLocalReferenceFullNames : undefined,
          ),
        ]),
      ),
    [markedLocalReferenceFullNames, visibleReferences],
  );
  const allReferenceGroupIds = useMemo(
    () => [...trees.values()].flatMap(collectGitReferenceGroupIds),
    [trees],
  );

  useLayoutEffect(() => {
    const element = scrollRef.current;
    if (!element) return;
    return bindScrollContainerWheel(element);
  }, []);

  return (
    <div className="flex h-full min-h-0 bg-surface/45 font-sans ui-text-sm select-none">
      <GitReferenceToolbar
        selectedReference={selectedReference}
        currentReference={currentReference}
        isMutating={isMutating}
        isPullLocked={isPullLocked}
        isMarked={
          selectedReference?.kind === "local" &&
          markedLocalReferenceFullNames.has(selectedReference.fullName)
        }
        hasReferences={references.length > 0}
        onReferenceAction={onReferenceAction}
        onFetch={onFetch}
        onToggleMark={() => {
          if (selectedReference?.kind === "local") {
            toggleMarkedReference(repoPath, selectedReference.fullName);
          }
        }}
        showMyBranchesOnly={showMyBranchesOnly}
        hasMyBranches={hasMyBranches}
        onToggleMyBranches={() => setShowMyBranchesOnly(!showMyBranchesOnly)}
        onNavigateToHead={onNavigateToHead}
        canNavigateToHead={
          Boolean(canNavigateToHead && (selectedReference ?? currentReference)) &&
          (selectedReference ?? currentReference)?.kind !== "tag"
        }
        onExpandAll={() => setReferenceExpansion([], [])}
        onCollapseAll={() =>
          setReferenceExpansion(
            SECTION_KEYS.map(({ kind }) => kind),
            allReferenceGroupIds,
          )
        }
      />
      <div className="flex min-w-0 flex-1 flex-col">
        <div className="flex h-8 shrink-0 items-center border-border border-b px-2 text-subtle-foreground">
          {t("git.log.references")}
          <span className="ml-auto tabular-nums">{visibleReferences.length}</span>
        </div>
        <div
          ref={scrollRef}
          data-scroll-container=""
          className="min-h-0 flex-1 overflow-auto p-1.5"
        >
          <button
            type="button"
            onClick={() => onSelect(currentReference)}
            className={cn(
              "mb-1 flex h-7 w-full items-center gap-2 rounded px-2 text-left font-medium hover:bg-accent/80",
              selectedReference?.fullName === currentReference?.fullName &&
                "bg-accent text-accent-foreground",
            )}
          >
            <span className="text-primary">→</span>
            <span className="truncate">{t("git.log.headCurrentBranch")}</span>
            {currentReference ? (
              <span className="ml-auto max-w-24 truncate text-subtle-foreground">
                {currentReference.shortName}
              </span>
            ) : null}
          </button>

          {SECTION_KEYS.map(({ kind, titleKey }) => {
            const collapsed = collapsedSections.has(kind);
            const nodes = trees.get(kind) ?? [];
            return (
              <div key={kind} className="mb-1">
                <ContextMenu>
                  <ContextMenuTrigger
                    render={<button type="button" />}
                    onClick={() => toggleReferenceSection(kind)}
                    className="flex h-6 w-full items-center gap-1.5 rounded px-1.5 text-left font-medium hover:bg-accent/80"
                  >
                    {collapsed ? (
                      <CaretRightIcon className="size-3" />
                    ) : (
                      <CaretDownIcon className="size-3" />
                    )}
                    {kind === "tag" ? (
                      <FolderIcon className="size-3.5 text-subtle-foreground" />
                    ) : null}
                    {t(titleKey)}
                    <span className="ml-auto text-subtle-foreground tabular-nums">
                      {countGitReferencesByKind(visibleReferences, kind)}
                    </span>
                  </ContextMenuTrigger>
                  {kind === "remote" ? (
                    <ContextMenuContent>
                      <ContextMenuItem onClick={onManageRemotes}>
                        <NetworkIcon />
                        {t("git.log.manageRemotes")}
                      </ContextMenuItem>
                    </ContextMenuContent>
                  ) : null}
                </ContextMenu>
                {!collapsed &&
                  (nodes.length ? (
                    nodes.map((node) => (
                      <ReferenceNode
                        key={node.id}
                        node={node}
                        kind={kind}
                        depth={0}
                        selectedFullName={selectedReference?.fullName}
                        collapsedGroups={collapsedGroups}
                        currentReference={currentReference}
                        remoteReferences={remoteReferences}
                        markedReferenceFullNames={markedLocalReferenceFullNames}
                        isMutating={isMutating}
                        isPullLocked={isPullLocked}
                        onToggleGroup={toggleReferenceGroup}
                        onSelect={onSelect}
                        onReferenceAction={onReferenceAction}
                        onSetUpstream={onSetUpstream}
                      />
                    ))
                  ) : (
                    <div className="h-6 pl-8 leading-6 text-subtle-foreground">
                      {t("git.log.none")}
                    </div>
                  ))}
              </div>
            );
          })}
        </div>
      </div>
    </div>
  );
}
