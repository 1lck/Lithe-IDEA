import { useEffect, useRef, useState } from "react";
import { open } from "@tauri-apps/plugin-dialog";
import { toast } from "sonner";
import { useActiveWorkspaceId } from "@/features/workspace/stores/create-workspace-scoped-store";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import { Checkbox } from "@/ui/checkbox";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  showConfirmDialog,
} from "@/ui/dialog";
import Input from "@/ui/input";
import Select from "@/ui/select";
import { Spinner } from "@/ui/spinner";
import { cancelGitHistoryOperation, getGitReferences } from "../api/git-commits-api";
import {
  createWorktree,
  readWorktrees,
  removeWorktree,
  type GitWorktreeMode,
} from "../api/git-worktrees-api";
import {
  attachGitWorktreeDialogHost,
  type GitWorktreeDialogRequest,
} from "../services/git-worktree-dialog-service";
import { useRepositoryStore } from "../stores/git-repository.store";
import type { GitReference, GitWorktree } from "../types/git.types";
import { isOpenableGitWorktree, openGitWorktreeWorkspace } from "../utils/git-worktree-open";
import { isGitChangeRelevant, subscribeToGitChanges } from "../events/git-events";

function GitWorktreeDialog({
  request,
  onClose,
}: {
  request: GitWorktreeDialogRequest;
  onClose: (changed: boolean) => void;
}) {
  const { t } = useTranslation();
  const [worktrees, setWorktrees] = useState<GitWorktree[]>([]);
  const [references, setReferences] = useState<GitReference[]>([]);
  const [selectedReference, setSelectedReference] = useState(request.reference?.fullName ?? "");
  const [mode, setMode] = useState<GitWorktreeMode>("newBranch");
  const [destination, setDestination] = useState(request.destination ?? "");
  const [name, setName] = useState("");
  const [revision, setRevision] = useState("");
  const [noCheckout, setNoCheckout] = useState(false);
  const [openTarget, setOpenTarget] = useState("new-window");
  const [status, setStatus] = useState<"loading" | "ready" | "failed" | "working">("loading");
  const [error, setError] = useState("");
  const [changed, setChanged] = useState(false);
  const [attempt, setAttempt] = useState(0);
  const alive = useRef(true);
  const working = useRef(false);

  useEffect(() => {
    alive.current = true;
    return () => {
      alive.current = false;
    };
  }, []);
  useEffect(() => {
    let current = true;
    const operationId = crypto.randomUUID();
    if (!working.current) setStatus("loading");
    void Promise.all([
      readWorktrees(request.repoPath),
      getGitReferences(request.repoPath, operationId),
    ])
      .then(([entries, refs]) => {
        if (!current) return;
        setWorktrees(entries);
        if (refs) {
          const choices = refs.references.filter((ref) => ref.peelsToCommit);
          setReferences(choices);
          setSelectedReference(
            (selected) =>
              selected ||
              choices.find((ref) => ref.isCurrent)?.fullName ||
              choices[0]?.fullName ||
              "",
          );
        }
        if (!working.current) setStatus("ready");
      })
      .catch((failure) => {
        if (current) {
          setError(String(failure));
          if (!working.current) setStatus("failed");
        }
      });
    return () => {
      current = false;
      void cancelGitHistoryOperation(operationId);
    };
  }, [request, attempt]);
  useEffect(
    () =>
      subscribeToGitChanges((change) => {
        if (
          isGitChangeRelevant(change, request.repoPath) &&
          (!change.scopes ||
            change.scopes.some((scope) => scope === "repository" || scope === "refs"))
        )
          setAttempt((value) => value + 1);
      }),
    [request.repoPath],
  );

  const reference = references.find((entry) => entry.fullName === selectedReference);
  const options = references
    .filter((entry) => mode !== "existingBranch" || entry.kind === "local")
    .map((entry) => {
      const occupied =
        mode === "existingBranch" &&
        worktrees.some((worktree) => worktree.branch === entry.shortName);
      return {
        value: entry.fullName,
        label: occupied
          ? `${entry.shortName} — ${t("git.worktreeDialog.branchInUse")}`
          : entry.shortName,
        disabled: occupied,
      };
    });
  const canCreate =
    destination.trim() &&
    (mode === "newBranch"
      ? name.trim() && reference
      : mode === "existingBranch"
        ? reference?.kind === "local" &&
          !worktrees.some((entry) => entry.branch === reference.shortName)
        : revision.trim() || reference);

  const openWorktree = async (
    path: string,
    target: "current-window" | "new-window",
    didChange = changed,
  ) => {
    if (target === "current-window") onClose(didChange);
    try {
      if (!(await openGitWorktreeWorkspace(path, { target })))
        throw new Error(t("git.worktreeDialog.openFailed"));
    } catch (failure) {
      toast.error(String(failure));
    }
  };
  const create = async () => {
    if (working.current || status !== "ready" || !canCreate) return;
    working.current = true;
    setStatus("working");
    setError("");
    try {
      await createWorktree(request.repoPath, {
        destination: destination.trim(),
        worktreeMode: mode,
        noCheckout,
        ...(mode === "newBranch" ? { name: name.trim() } : {}),
        ...(mode === "detached" && revision.trim() ? { revision: revision.trim() } : { reference }),
      });
      if (!alive.current) return;
      setChanged(true);
      const refreshed = await readWorktrees(request.repoPath);
      if (!alive.current) return;
      setWorktrees(refreshed);
      if (openTarget !== "stay")
        await openWorktree(destination.trim(), openTarget as "current-window" | "new-window", true);
      if (alive.current) {
        setName("");
        setDestination("");
        setStatus("ready");
      }
    } catch (failure) {
      if (alive.current) {
        setError(String(failure));
        setStatus("ready");
      }
    } finally {
      working.current = false;
    }
  };
  const remove = async (worktree: GitWorktree) => {
    if (
      working.current ||
      worktree.is_current ||
      worktree.is_primary !== false ||
      worktree.is_locked !== false ||
      worktree.is_prunable ||
      worktree.is_bare
    )
      return;
    if (
      !(await showConfirmDialog(t("git.worktreeDialog.removeConfirm", { path: worktree.path }), {
        title: t("git.worktreeDialog.remove"),
        confirmLabel: t("git.worktreeDialog.remove"),
      })) ||
      !alive.current
    )
      return;
    working.current = true;
    setStatus("working");
    setError("");
    try {
      await removeWorktree(request.repoPath, worktree.path, false);
      if (alive.current) {
        setChanged(true);
        setAttempt((value) => value + 1);
      }
    } catch (failure) {
      if (alive.current) setError(String(failure));
    } finally {
      working.current = false;
      if (alive.current) setStatus("ready");
    }
  };

  return (
    <Dialog
      open
      onOpenChange={(isOpen) => {
        if (!isOpen && !working.current) onClose(changed);
      }}
    >
      <DialogContent size="lg" className="max-w-3xl" showCloseButton={status !== "working"}>
        <DialogHeader>
          <DialogTitle>{t("git.worktrees")}</DialogTitle>
          <DialogDescription>{t("git.worktreeDialog.description")}</DialogDescription>
        </DialogHeader>
        <div className="min-h-0 space-y-4 overflow-auto px-5 py-4 ui-text-sm">
          <div className="max-h-64 space-y-2 overflow-auto">
            {worktrees.map((worktree) => {
              const protection = worktree.is_primary
                ? t("git.worktreeDialog.primary")
                : worktree.is_current
                  ? t("git.current")
                  : worktree.is_locked || worktree.locked_reason
                    ? t("git.worktreeDialog.locked")
                    : worktree.is_prunable
                      ? t("git.worktreeDialog.missing")
                      : worktree.is_bare
                        ? t("git.worktreeDialog.bare")
                        : "";
              return (
                <div key={worktree.path} className="space-y-2 rounded-md border border-border p-3">
                  <p className="break-all font-medium">{worktree.path}</p>
                  <p className="text-subtle-foreground">
                    {worktree.branch ?? t("git.detachedHead")}
                    {protection ? ` · ${protection}` : ""}
                  </p>
                  <div className="flex flex-wrap gap-2">
                    <Button
                      size="xs"
                      disabled={status === "working" || !isOpenableGitWorktree(worktree)}
                      onClick={() => void openWorktree(worktree.path, "current-window")}
                    >
                      {t("git.worktreeDialog.openCurrent")}
                    </Button>
                    <Button
                      size="xs"
                      disabled={status === "working" || !isOpenableGitWorktree(worktree)}
                      onClick={() => void openWorktree(worktree.path, "new-window")}
                    >
                      {t("git.worktreeDialog.openNew")}
                    </Button>
                    <Button
                      size="xs"
                      variant="danger"
                      disabled={
                        status === "working" ||
                        !!protection ||
                        worktree.is_primary !== false ||
                        worktree.is_locked !== false
                      }
                      title={protection || undefined}
                      onClick={() => void remove(worktree)}
                    >
                      {t("git.worktreeDialog.remove")}
                    </Button>
                  </div>
                </div>
              );
            })}
          </div>
          <div className="space-y-3 border-t border-border pt-3">
            <p className="font-medium">{t("git.newWorktree")}</p>
            <Select
              value={mode}
              disabled={status === "working"}
              onChange={(value) => {
                setMode(value as GitWorktreeMode);
                if (value === "existingBranch" && reference?.kind !== "local")
                  setSelectedReference(
                    references.find((entry) => entry.kind === "local")?.fullName ?? "",
                  );
              }}
              aria-label={t("git.worktreeDialog.mode")}
              options={(["newBranch", "existingBranch", "detached"] as const).map((value) => ({
                value,
                label: t(`git.worktreeDialog.mode.${value}`),
              }))}
            />
            <Select
              value={selectedReference}
              options={options}
              onChange={setSelectedReference}
              disabled={status === "working" || (mode === "detached" && !!revision.trim())}
              aria-label={t("git.worktreeDialog.reference")}
              searchable
            />
            {mode === "newBranch" ? (
              <label className="block space-y-1">
                <span>{t("git.worktreeDialog.branchName")}</span>
                <Input
                  value={name}
                  onChange={(event) => setName(event.target.value)}
                  disabled={status === "working"}
                />
              </label>
            ) : null}
            {mode === "detached" ? (
              <label className="block space-y-1">
                <span>{t("git.worktreeDialog.revision")}</span>
                <Input
                  value={revision}
                  onChange={(event) => setRevision(event.target.value)}
                  disabled={status === "working"}
                  placeholder={t("git.worktreeDialog.revisionHint")}
                />
              </label>
            ) : null}
            <label className="block space-y-1">
              <span>{t("git.worktreeDialog.destination")}</span>
              <div className="flex gap-2">
                <Input
                  value={destination}
                  onChange={(event) => setDestination(event.target.value)}
                  disabled={status === "working"}
                />
                <Button
                  disabled={status === "working"}
                  onClick={() => {
                    void open({
                      directory: true,
                      multiple: false,
                      title: t("git.worktreeDialog.destination"),
                    })
                      .then((path) => {
                        if (alive.current && path && !Array.isArray(path)) setDestination(path);
                      })
                      .catch((failure) => {
                        if (alive.current) setError(String(failure));
                      });
                  }}
                >
                  {t("ui.browse")}
                </Button>
              </div>
            </label>
            <label className="flex items-start gap-2">
              <Checkbox
                checked={noCheckout}
                onCheckedChange={(checked) => {
                  setNoCheckout(checked === true);
                  if (checked) setOpenTarget("stay");
                }}
                disabled={status === "working"}
              />
              <span>{t("git.worktreeDialog.noCheckout")}</span>
            </label>
            <Select
              value={openTarget}
              onChange={setOpenTarget}
              disabled={status === "working"}
              aria-label={t("git.worktreeDialog.afterCreate")}
              options={(["stay", "current-window", "new-window"] as const).map((value) => ({
                value,
                label: t(`git.worktreeDialog.after.${value}`),
              }))}
            />
          </div>
          {status === "loading" ? <Spinner label={t("ui.loading")} showLabel /> : null}
          {error ? (
            <p role="alert" className="whitespace-pre-wrap text-destructive">
              {error}
            </p>
          ) : null}
        </div>
        <DialogFooter>
          <Button disabled={status === "working"} onClick={() => onClose(changed)}>
            {t("ui.done")}
          </Button>
          <Button disabled={status === "working"} onClick={() => setAttempt((value) => value + 1)}>
            {t("ui.refresh")}
          </Button>
          <Button
            variant="accent"
            disabled={status !== "ready" || !canCreate}
            onClick={() => void create()}
          >
            {t("git.create")}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

export function GitWorktreeDialogHost() {
  const [request, setRequest] = useState<GitWorktreeDialogRequest | null>(null);
  const requestRef = useRef<GitWorktreeDialogRequest | null>(null);
  const workspaceId = useActiveWorkspaceId();
  const selectedRepository = useRepositoryStore((state) => state.activeRepoPath);
  const close = (changed: boolean) => {
    requestRef.current?.resolve(changed);
    requestRef.current = null;
    setRequest(null);
  };
  useEffect(() => {
    const detach = attachGitWorktreeDialogHost((next) => {
      if (requestRef.current) {
        next.resolve(false);
        return;
      }
      requestRef.current = next;
      setRequest(next);
    });
    return () => {
      detach();
      requestRef.current?.resolve(false);
      requestRef.current = null;
    };
  }, []);
  const current =
    request?.workspaceId === workspaceId && request.selectedRepository === selectedRepository;
  useEffect(() => {
    if (request && !current) close(false);
  }, [request, current]);
  return request && current ? (
    <GitWorktreeDialog key={request.id} request={request} onClose={close} />
  ) : null;
}
