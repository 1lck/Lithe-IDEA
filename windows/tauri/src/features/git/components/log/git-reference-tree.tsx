import {
  ArrowClockwiseIcon,
  CaretDownIcon,
  CaretRightIcon,
  CheckIcon,
  FolderIcon,
  FolderPlusIcon,
  GitBranchIcon,
  GitDiffIcon,
  GitMergeIcon,
  NetworkIcon,
  PencilIcon,
  PlusIcon,
  TagIcon,
  TrashIcon,
  UploadIcon,
} from "@/ui/icons";
import { useLayoutEffect, useMemo, useRef } from "react";
import { cn } from "@/utils/cn";
import { useTranslation } from "@/i18n/locale-provider";
import { bindScrollContainerWheel } from "@/ui/scroll-container-wheel";
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
  type GitReferenceAction,
} from "../../utils/git-reference-actions";
import {
  buildGitReferenceTree,
  countGitReferencesByKind,
  type GitReferenceTreeNode,
} from "../../utils/git-reference-tree";
import { GitTrackingCounts } from "../git-tracking-counts";

const SECTION_KEYS: Array<{ kind: GitReferenceKind; titleKey: string }> = [
  { kind: "local", titleKey: "git.log.local" },
  { kind: "remote", titleKey: "git.log.remote" },
  { kind: "tag", titleKey: "git.log.tags" },
];

function ReferenceIcon({ kind, isCurrent = false }: { kind: GitReferenceKind; isCurrent?: boolean }) {
  if (isCurrent) return <CheckIcon className="size-3.5 text-amber-400" />;
  if (kind === "tag") return <TagIcon className="size-3.5 text-amber-400" />;
  if (kind === "remote") return <NetworkIcon className="size-3.5 text-subtle-foreground" />;
  return <GitBranchIcon className="size-3.5 text-subtle-foreground" />;
}

interface GitReferenceTreeProps {
  references: GitReference[];
  selectedReference: GitReference | null;
  isMutating?: boolean;
  onSelect: (reference: GitReference | null) => void;
  onReferenceAction: (action: GitReferenceAction, reference: GitReference) => void;
  onSetUpstream: (branch: GitReference, upstream: GitReference | null) => void;
  onManageRemotes: () => void;
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

function ReferenceActionMenu({
  reference,
  currentReference,
  remoteReferences,
  isMutating,
  onAction,
  onSetUpstream,
}: {
  reference: GitReference;
  currentReference: GitReference | null;
  remoteReferences: GitReference[];
  isMutating: boolean;
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
                (action === "checkoutAndUpdate" && !reference.upstreamShortName) ||
                (action === "update" && !reference.isCurrent);
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
  isMutating,
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
  isMutating: boolean;
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
          <ReferenceIcon kind={kind} isCurrent={node.reference?.isCurrent} />
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
            isMutating={isMutating}
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
  references,
  selectedReference,
  isMutating = false,
  onSelect,
  onReferenceAction,
  onSetUpstream,
  onManageRemotes,
}: GitReferenceTreeProps) {
  const { t } = useTranslation();
  const collapsedSectionIds = useGitLogPreferencesStore.use.collapsedReferenceSections();
  const collapsedGroupIds = useGitLogPreferencesStore.use.collapsedReferenceGroups();
  const { toggleReferenceSection, toggleReferenceGroup } = useGitLogPreferencesStore.use.actions();
  const scrollRef = useRef<HTMLDivElement>(null);
  const collapsedSections = useMemo(() => new Set(collapsedSectionIds), [collapsedSectionIds]);
  const collapsedGroups = useMemo(() => new Set(collapsedGroupIds), [collapsedGroupIds]);
  const currentReference = references.find((reference) => reference.isCurrent) ?? null;
  const remoteReferences = useMemo(
    () => references.filter((reference) => reference.kind === "remote"),
    [references],
  );
  const trees = useMemo(
    () => new Map(SECTION_KEYS.map(({ kind }) => [kind, buildGitReferenceTree(references, kind)])),
    [references],
  );

  useLayoutEffect(() => {
    const element = scrollRef.current;
    if (!element) return;
    return bindScrollContainerWheel(element);
  }, []);

  return (
    <div className="flex h-full min-h-0 flex-col bg-surface/45 font-sans ui-text-sm select-none">
      <div className="flex h-8 shrink-0 items-center border-border border-b px-2 text-subtle-foreground">
        {t("git.log.references")}
        <span className="ml-auto tabular-nums">{references.length}</span>
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
                  <FolderIcon className="size-3.5 text-subtle-foreground" />
                  {t(titleKey)}
                  <span className="ml-auto text-subtle-foreground tabular-nums">
                    {countGitReferencesByKind(references, kind)}
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
                      isMutating={isMutating}
                      onToggleGroup={toggleReferenceGroup}
                      onSelect={onSelect}
                      onReferenceAction={onReferenceAction}
                      onSetUpstream={onSetUpstream}
                    />
                  ))
                ) : (
                  <div className="h-6 pl-8 leading-6 text-subtle-foreground">{t("git.log.none")}</div>
                ))}
            </div>
          );
        })}
      </div>
    </div>
  );
}
