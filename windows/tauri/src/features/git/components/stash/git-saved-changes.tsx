import { useEffect, useRef, useState } from "react";
import { useTranslation } from "@/i18n/locale-provider";
import { createStash, applyStash, popStash, dropStash, getStashes } from "../../api/git-stash-api";
import { getStashDiff } from "../../api/git-diff-api";
import {
  listShelves,
  deleteShelf,
  shelveChanges,
  restoreShelf,
  inspectShelfDiffs,
  assertSavedFiles,
} from "../../api/git-shelf-api";
import type { GitShelf } from "../../services/git-shelf-workflow";
import type { GitDiff, GitStash } from "../../types/git.types";
import {
  DropdownMenu,
  DropdownMenuTrigger,
  DropdownMenuContent,
  DropdownMenuRadioGroup,
  DropdownMenuRadioItem,
} from "@/ui/dropdown-menu";
import { ResizablePanelGroup, ResizablePanel, ResizableHandle } from "@/ui/resizable";
import { createMultiFileDiff } from "../../utils/multi-file-diff";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { activateMainEditorPane } from "@/features/editor/stores/buffer-pane-sync";
import { FileNavigatorSidebar } from "@/features/file-explorer/components/file-navigator-sidebar";
import { Button } from "@/ui/button";
import { Checkbox } from "@/ui/checkbox";
import Input from "@/ui/input";
import Dialog, { showConfirmDialog } from "@/ui/dialog";
import { SidebarTreeRow } from "@/features/sidebar/components/sidebar-tree";
import { ArchiveIcon, PlusIcon, TrashIcon, RefreshIcon } from "@/ui/icons";
import { formatShortDateTime } from "@/utils/date";
import { subscribeToGitChanges, isGitChangeRelevant } from "../../events/git-events";

type RepositorySession = { root: string };
type SavedChangesState = { owner: RepositorySession; revision: number } & (
  | { status: "loading" | "failed" }
  | { status: "ready"; shelves: GitShelf[]; stashes: GitStash[] }
);
type Selection = { owner: RepositorySession } & (
  | { kind: "shelf"; entry: GitShelf }
  | { kind: "stash"; entry: GitStash }
);
export function GitSavedChanges({
  root,
  disabled = false,
  operationBusy = false,
  onRefresh,
  onOperationStart,
}: {
  root: string;
  disabled?: boolean;
  operationBusy?: boolean;
  onOperationStart: () => (() => void) | undefined;
  onRefresh: () => Promise<unknown> | void;
}) {
  const { t } = useTranslation();
  const [savedChanges, setSavedChanges] = useState<SavedChangesState>();
  const [selected, setSelection] = useState<Selection>();
  const [version, setVersion] = useState<"staged" | "worktree">("worktree");
  const [diffs, setDiffs] = useState<GitDiff[]>([]);
  const [diffLoading, setDiffLoading] = useState(false);
  const [busy, setBusy] = useState(false);
  const runningSession = useRef<RepositorySession | null>(null);
  const currentSession = useRef<RepositorySession>({ root });
  // A -> B -> A must invalidate operations started during the first A visit.
  if (currentSession.current.root !== root) currentSession.current = { root };
  const session = currentSession.current;
  const live = useRef(true);
  const disabledRef = useRef(disabled);
  disabledRef.current = disabled;
  useEffect(() => {
    live.current = true;
    return () => {
      live.current = false;
    };
  }, []);
  const generation = useRef(0);
  const [revision, setRevision] = useState(0);
  const externalOperationPending = useRef(operationBusy);
  const currentChanges =
    savedChanges?.owner === session && savedChanges.revision === revision
      ? savedChanges
      : undefined;
  const readyChanges = currentChanges?.status === "ready" ? currentChanges : undefined;
  const readyChangesRef = useRef(readyChanges);
  readyChangesRef.current = readyChanges;
  const loading = !currentChanges || currentChanges.status === "loading";
  const shelves = readyChanges?.shelves ?? [];
  const stashes = readyChanges?.stashes ?? [];
  const selection =
    readyChanges &&
    selected?.owner === session &&
    (selected.kind === "shelf"
      ? shelves.some((entry) => entry.id === selected.entry.id)
      : stashes.some((entry) => entry.oid === selected.entry.oid))
      ? selected
      : undefined;
  const [query, setQuery] = useState("");
  const [error, setError] = useState<string>();
  const [createKind, setCreateKind] = useState<"stash" | "shelf">();
  const [message, setMessage] = useState("");
  const [includeUntracked, setIncludeUntracked] = useState(true);
  const selectedId =
    selection?.kind === "shelf"
      ? selection.entry.id
      : selection
        ? `stash:${selection.entry.oid ?? selection.entry.index}`
        : "";
  const refresh = () => setRevision((value) => value + 1);
  useEffect(() => {
    if (operationBusy) {
      if (runningSession.current !== session) externalOperationPending.current = true;
    } else if (externalOperationPending.current) {
      externalOperationPending.current = false;
      // Native storage can finish after unmount or after this pane leaves its original session.
      setRevision((value) => value + 1);
    }
  }, [operationBusy, session]);
  useEffect(
    () =>
      subscribeToGitChanges((change) => {
        if (isGitChangeRelevant(change, root)) refresh();
      }),
    [root],
  );
  useEffect(() => {
    setSelection(undefined);
    setDiffs([]);
    setError(undefined);
    setCreateKind(undefined);
  }, [session]);
  useEffect(() => {
    const request = ++generation.current;
    setSavedChanges({ owner: session, revision, status: "loading" });
    void Promise.all([listShelves(root), getStashes(root, "unknown", true)])
      .then(([nextShelves, nextStashes]) => {
        if (generation.current !== request || currentSession.current !== session) return;
        setSavedChanges({
          owner: session,
          revision,
          status: "ready",
          shelves: nextShelves,
          stashes: nextStashes,
        });
        setSelection((current) => {
          if (current?.owner !== session) return undefined;
          if (current.kind === "shelf") {
            const entry = nextShelves.find((entry) => entry.id === current.entry.id);
            return entry ? { owner: session, kind: "shelf", entry } : undefined;
          }
          const entry = nextStashes.find((entry) => entry.oid === current.entry.oid);
          return entry ? { owner: session, kind: "stash", entry } : undefined;
        });
      })
      .catch((failure) => {
        if (generation.current !== request || currentSession.current !== session) return;
        setSavedChanges({ owner: session, revision, status: "failed" });
        setSelection(undefined);
        setError(String(failure));
      });
    return () => {
      generation.current++;
    };
  }, [root, session, revision]);
  useEffect(() => {
    let cancelled = false;
    setDiffs([]);
    setDiffLoading(Boolean(selection));
    const load = async () => {
      if (!selection) return [];
      if (selection.kind === "shelf")
        return inspectShelfDiffs(
          root,
          version === "staged" ? selection.entry.stagedPatch : selection.entry.workingPatch,
          () => !cancelled,
        );
      const value = await getStashDiff(root, selection.entry.index, selection.entry.oid);
      if (!value) throw new Error("git.saved.failed");
      return value;
    };
    void load()
      .then((value) => {
        if (!cancelled) setDiffs(value);
      })
      .catch((failure) => {
        if (!cancelled)
          setError(
            failure instanceof Error && failure.message.startsWith("git.saved.")
              ? t(failure.message as "git.saved.failed")
              : String(failure),
          );
      })
      .finally(() => {
        if (!cancelled) setDiffLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, [root, selection, version, revision, t]);
  const guard = () => {
    if (!live.current || currentSession.current !== session || disabledRef.current)
      throw new Error("git.saved.changed");
  };
  const run = async (action: () => Promise<unknown>) => {
    if (
      runningSession.current ||
      operationBusy ||
      disabled ||
      !readyChanges ||
      readyChangesRef.current !== readyChanges
    )
      return;
    const releaseOperation = onOperationStart();
    if (!releaseOperation) return;
    runningSession.current = session;
    setBusy(true);
    setError(undefined);
    try {
      guard();
      await action();
      if (live.current && currentSession.current === session) {
        refresh();
        await onRefresh();
      }
    } catch (failure) {
      if (live.current && currentSession.current === session) {
        const key = failure instanceof Error ? failure.message : String(failure);
        setError(key.startsWith("git.saved.") ? t(key as "git.saved.changed") : key);
        refresh();
      }
    } finally {
      runningSession.current = null;
      releaseOperation();
      if (live.current) setBusy(false);
    }
  };
  const mutate = (operation: "apply" | "pop" | "drop") =>
    run(async () => {
      if (!selection) return;
      if (operation === "drop" && !(await showConfirmDialog(t("git.saved.drop")))) return;
      guard();
      if (selection.owner !== session || readyChangesRef.current !== readyChanges)
        throw new Error("git.saved.changed");
      if (operation !== "drop") assertSavedFiles(root);
      if (selection.kind === "shelf") {
        if (operation === "drop") await deleteShelf(root, selection.entry.id);
        else await restoreShelf(root, selection.entry, guard);
      } else {
        const current = (await getStashes(root, "unknown", true)).find(
          (entry) => entry.oid === selection.entry.oid,
        );
        guard();
        if (operation !== "drop") assertSavedFiles(root);
        if (!current || !selection.entry.oid || current.oid !== selection.entry.oid)
          throw new Error("git.saved.changed");
        const success = await (
          operation === "drop" ? dropStash : operation === "pop" ? popStash : applyStash
        )(root, current.index, current.oid);
        if (!success) throw new Error("git.saved.failed");
      }
    });
  const openDiff = (path: string) => {
    activateMainEditorPane();
    const data = createMultiFileDiff({
      repoPath: root,
      commitHash: selectedId,
      diffs,
      initialFilePath: path,
    });
    useBufferStore
      .getState()
      .actions.openBuffer(
        `diff://saved/${encodeURIComponent(root)}/${selectedId}/${version}`,
        selection?.entry.message ?? "",
        "",
        false,
        undefined,
        true,
        true,
        data,
      );
  };
  const locked = busy || operationBusy || disabled || !readyChanges;
  return (
    <div className="flex min-h-0 flex-1 flex-col" aria-busy={loading || busy}>
      <div className="flex items-center gap-1 border-b border-border px-2 py-1">
        <Button
          variant="ghost"
          size="xs"
          disabled={locked}
          onClick={() => {
            setMessage("");
            setCreateKind("stash");
          }}
        >
          <PlusIcon />
          {t("git.createStash")}
        </Button>
        <Button
          variant="ghost"
          size="xs"
          disabled={locked}
          onClick={() => {
            setMessage("");
            setCreateKind("shelf");
          }}
        >
          {t("git.saved.shelve")}
        </Button>
        <Button
          variant="ghost"
          size="icon-xs"
          aria-label={t("files.refresh")}
          disabled={busy || operationBusy || disabled || loading}
          onClick={refresh}
        >
          <RefreshIcon />
        </Button>
      </div>
      <div className="px-2 py-1">
        <Input
          value={query}
          onChange={(event) => setQuery(event.target.value)}
          placeholder={t("git.searchStashes")}
        />
      </div>
      {error && (
        <div role="alert" className="px-2 py-1 ui-text-sm text-destructive">
          {error}
        </div>
      )}
      <ResizablePanelGroup orientation="vertical" className="min-h-0 flex-1">
        <ResizablePanel defaultSize="50%" minSize="20%">
          <div className="h-full overflow-auto">
            {(["shelf", "stash"] as const).map((kind) => (
              <div key={kind}>
                <div className="px-2 py-1 ui-text-sm text-subtle-foreground">
                  {t(kind === "shelf" ? "git.saved.shelves" : "git.saved.stashes")}
                </div>
                {(kind === "shelf" ? shelves : stashes)
                  .filter((entry) => entry.message.toLowerCase().includes(query.toLowerCase()))
                  .map((entry) => {
                    const id = "id" in entry ? entry.id : `stash:${entry.oid ?? entry.index}`;
                    return (
                      <SidebarTreeRow
                        key={id}
                        depth={0}
                        variant="idea"
                        disabled={locked}
                        active={id === selectedId}
                        label={entry.message}
                        leading={<ArchiveIcon />}
                        description={
                          "createdAt" in entry ? formatShortDateTime(entry.createdAt) : entry.date
                        }
                        onClick={() => {
                          setSelection(
                            "id" in entry
                              ? { owner: session, kind: "shelf", entry }
                              : { owner: session, kind: "stash", entry },
                          );
                          setVersion("worktree");
                        }}
                      />
                    );
                  })}
              </div>
            ))}
            {readyChanges && !shelves.length && !stashes.length && (
              <div className="p-3 text-subtle-foreground ui-text-sm">{t("git.saved.empty")}</div>
            )}
          </div>
        </ResizablePanel>
        <ResizableHandle />
        <ResizablePanel defaultSize="50%" minSize="20%" className="flex min-h-0 flex-col">
          {selection && (
            <>
              <div className="flex flex-wrap items-center gap-1 px-2 py-1">
                <Button
                  size="xs"
                  variant="ghost"
                  disabled={locked}
                  onClick={() => void mutate("apply")}
                >
                  {t(selection.kind === "shelf" ? "git.saved.restore" : "git.apply")}
                </Button>
                {selection.kind === "stash" && (
                  <Button
                    size="xs"
                    variant="ghost"
                    disabled={locked}
                    onClick={() => void mutate("pop")}
                  >
                    {t("git.pop")}
                  </Button>
                )}
                <Button
                  size="icon-xs"
                  variant="ghost"
                  aria-label={t("files.delete")}
                  disabled={locked}
                  onClick={() => void mutate("drop")}
                >
                  <TrashIcon />
                </Button>
                {selection.kind === "shelf" && (
                  <DropdownMenu>
                    <DropdownMenuTrigger className="ml-auto ui-text-sm">
                      {t(version === "staged" ? "git.saved.staged" : "git.saved.worktree")}
                    </DropdownMenuTrigger>
                    <DropdownMenuContent>
                      <DropdownMenuRadioGroup
                        value={version}
                        onValueChange={(value) => setVersion(value as typeof version)}
                      >
                        <DropdownMenuRadioItem value="staged">
                          {t("git.saved.staged")}
                        </DropdownMenuRadioItem>
                        <DropdownMenuRadioItem value="worktree">
                          {t("git.saved.worktree")}
                        </DropdownMenuRadioItem>
                      </DropdownMenuRadioGroup>
                    </DropdownMenuContent>
                  </DropdownMenu>
                )}
              </div>
              {diffLoading ? (
                <div className="p-2 text-subtle-foreground">{t("git.loadingGitStatus")}</div>
              ) : (
                <div className="min-h-0 flex-1">
                  <FileNavigatorSidebar
                    fitWidth
                    surface="plain"
                    items={diffs.map((diff) => ({ key: diff.file_path, path: diff.file_path }))}
                    selectedKey={null}
                    onSelect={openDiff}
                    searchResetKey={`${root}:${selectedId}:${version}`}
                  />
                </div>
              )}
            </>
          )}
        </ResizablePanel>
      </ResizablePanelGroup>
      {createKind && (
        <Dialog
          title={t(createKind === "shelf" ? "git.saved.shelve" : "git.createStash")}
          onClose={() => {
            if (!busy) setCreateKind(undefined);
          }}
          footer={
            <Button
              disabled={locked}
              onClick={() =>
                void run(async () => {
                  assertSavedFiles(root);
                  if (createKind === "shelf") await shelveChanges(root, message, guard);
                  else if (!(await createStash(root, message, includeUntracked)))
                    throw new Error("git.saved.failed");
                  if (live.current && currentSession.current === session) setCreateKind(undefined);
                })
              }
            >
              {t("git.create")}
            </Button>
          }
        >
          {error && (
            <div role="alert" className="mb-2 text-destructive">
              {error}
            </div>
          )}
          <Input
            autoFocus
            value={message}
            onChange={(event) => setMessage(event.target.value)}
            placeholder={t("git.stashMessage")}
            disabled={busy}
          />
          {createKind === "stash" && (
            <label className="mt-2 flex items-center gap-2">
              <Checkbox
                checked={includeUntracked}
                onCheckedChange={setIncludeUntracked}
                disabled={busy}
              />
              {t("git.saved.untracked")}
            </label>
          )}
        </Dialog>
      )}
    </div>
  );
}
