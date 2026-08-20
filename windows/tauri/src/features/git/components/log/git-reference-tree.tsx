import {
  CaretDownIcon,
  CaretRightIcon,
  FolderIcon,
  GitBranchIcon,
  NetworkIcon,
  TagIcon,
} from "@/ui/icons";
import { useLayoutEffect, useMemo, useRef } from "react";
import { bindScrollContainerWheel } from "@/ui/scroll-container-wheel";
import { cn } from "@/utils/cn";
import { useTranslation } from "@/i18n/locale-provider";
import { useGitLogPreferencesStore } from "../../stores/git-log-preferences.store";
import type { GitReference, GitReferenceKind } from "../../types/git.types";
import { buildGitReferenceTree, type GitReferenceTreeNode } from "../../utils/git-reference-tree";

const SECTION_KEYS: Array<{ kind: GitReferenceKind; titleKey: string }> = [
  { kind: "local", titleKey: "git.log.local" },
  { kind: "remote", titleKey: "git.log.remote" },
  { kind: "tag", titleKey: "git.log.tags" },
];

function ReferenceIcon({ kind }: { kind: GitReferenceKind }) {
  if (kind === "tag") return <TagIcon className="size-3.5 text-amber-400" />;
  if (kind === "remote") return <NetworkIcon className="size-3.5 text-subtle-foreground" />;
  return <GitBranchIcon className="size-3.5 text-subtle-foreground" />;
}

function ReferenceNode({
  node,
  kind,
  depth,
  selectedFullName,
  collapsedGroups,
  onToggleGroup,
  onSelect,
}: {
  node: GitReferenceTreeNode;
  kind: GitReferenceKind;
  depth: number;
  selectedFullName?: string;
  collapsedGroups: Set<string>;
  onToggleGroup: (id: string) => void;
  onSelect: (reference: GitReference) => void;
}) {
  const { t } = useTranslation();
  const isGroup = node.children.length > 0;
  const isCollapsed = collapsedGroups.has(node.id);
  const left = 10 + depth * 14;

  return (
    <>
      <div
        className={cn(
          "flex h-6 w-full min-w-0 items-center gap-1.5 rounded px-1.5 text-left hover:bg-accent/80",
          node.reference?.fullName === selectedFullName && "bg-accent text-accent-foreground",
        )}
        style={{ paddingLeft: left }}
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
            <ReferenceIcon kind={kind} />
          )}
          <span className="truncate">{node.name}</span>
        </button>
      </div>
      {!isCollapsed &&
        node.children.map((child) => (
          <ReferenceNode
            key={child.id}
            node={child}
            kind={kind}
            depth={depth + 1}
            selectedFullName={selectedFullName}
            collapsedGroups={collapsedGroups}
            onToggleGroup={onToggleGroup}
            onSelect={onSelect}
          />
        ))}
    </>
  );
}

export function GitReferenceTree({
  references,
  selectedReference,
  onSelect,
}: {
  references: GitReference[];
  selectedReference: GitReference | null;
  onSelect: (reference: GitReference | null) => void;
}) {
  const { t } = useTranslation();
  const collapsedSectionIds = useGitLogPreferencesStore.use.collapsedReferenceSections();
  const collapsedGroupIds = useGitLogPreferencesStore.use.collapsedReferenceGroups();
  const { toggleReferenceSection, toggleReferenceGroup } = useGitLogPreferencesStore.use.actions();
  const collapsedSections = useMemo(() => new Set(collapsedSectionIds), [collapsedSectionIds]);
  const collapsedGroups = useMemo(() => new Set(collapsedGroupIds), [collapsedGroupIds]);
  const currentReference = references.find((reference) => reference.isCurrent) ?? null;
  const trees = useMemo(
    () => new Map(SECTION_KEYS.map(({ kind }) => [kind, buildGitReferenceTree(references, kind)])),
    [references],
  );
  const scrollRef = useRef<HTMLDivElement>(null);

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
      <div ref={scrollRef} className="min-h-0 flex-1 overflow-auto p-1.5">
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
              <button
                type="button"
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
                <span className="ml-auto text-subtle-foreground tabular-nums">{nodes.length}</span>
              </button>
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
                      onToggleGroup={toggleReferenceGroup}
                      onSelect={onSelect}
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
