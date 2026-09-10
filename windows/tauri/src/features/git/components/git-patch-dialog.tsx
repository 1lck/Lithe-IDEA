import { useEffect, useRef, useState } from "react";
import { open, save } from "@tauri-apps/plugin-dialog";
import { useActiveWorkspaceId } from "@/features/workspace/stores/create-workspace-scoped-store";
import { useTranslation } from "@/i18n/locale-provider";
import { readGitPatchFile, writeGitPatchFile } from "@/platform/git-patch-files";
import { Button } from "@/ui/button";
import { Checkbox } from "@/ui/checkbox";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/ui/dialog";
import Select from "@/ui/select";
import { Spinner } from "@/ui/spinner";
import Textarea from "@/ui/textarea";
import { cancelGitHistoryOperation } from "../api/git-commits-api";
import { applyGitPatch, exportGitPatch, previewGitPatch } from "../api/git-patch-api";
import {
  attachGitPatchDialogHost,
  type GitPatchDialogRequest,
} from "../services/git-patch-dialog-service";
import { useRepositoryStore } from "../stores/git-repository.store";
import {
  GIT_PATCH_MAX_BYTES,
  type GitPatchExport,
  type GitPatchFile,
  type GitPatchPreview,
  type GitPatchSource,
  type GitPatchTarget,
} from "../types/git-patch.types";
import type { GitOperationWarning } from "../types/git.types";

const PATCH_DISPLAY_CHARACTERS = 128 * 1024;

function PatchFileList({
  files,
  selected,
  onToggle,
}: {
  files: GitPatchFile[];
  selected?: ReadonlySet<string>;
  onToggle?: (path: string, checked: boolean) => void;
}) {
  return (
    <ul className="max-h-40 overflow-auto rounded-md border border-border p-2">
      {files.map((file) => (
        <li key={file.path} className="py-1">
          <label className="flex min-w-0 items-start gap-2">
            {selected && onToggle ? (
              <Checkbox
                checked={selected.has(file.path)}
                onCheckedChange={(checked) => onToggle(file.path, checked === true)}
                aria-label={file.path}
              />
            ) : null}
            <span className="min-w-0 flex-1 break-all">
              {file.originalPath ? `${file.originalPath} → ` : ""}
              {file.path}
            </span>
            <span className="shrink-0 font-mono text-subtle-foreground">
              {file.additions === null ? "—" : `+${file.additions}`} /{" "}
              {file.deletions === null ? "—" : `−${file.deletions}`}
            </span>
          </label>
        </li>
      ))}
    </ul>
  );
}

function RawPatchPreview({ patch }: { patch: string }) {
  const { t } = useTranslation();
  return (
    <div className="space-y-1">
      <p className="font-medium">{t("git.patch.rawDiff")}</p>
      <pre className="max-h-60 overflow-auto rounded-md border border-border bg-surface p-3 font-mono text-xs select-text">
        {patch.slice(0, PATCH_DISPLAY_CHARACTERS)}
      </pre>
      {patch.length > PATCH_DISPLAY_CHARACTERS ? (
        <p className="text-subtle-foreground">{t("git.patch.displayTruncated")}</p>
      ) : null}
    </div>
  );
}

function PatchExportDialog({
  request,
  onClose,
}: {
  request: GitPatchDialogRequest;
  onClose: (completed: boolean) => void;
}) {
  const { t } = useTranslation();
  const [source, setSource] = useState<GitPatchSource>(
    request.commits?.length === 2 ? "commits" : "workingTree",
  );
  const [baseRevision, setBaseRevision] = useState(request.commits?.[1]?.hash ?? "");
  const [targetRevision, setTargetRevision] = useState(request.commits?.[0]?.hash ?? "");
  const [files, setFiles] = useState<GitPatchFile[]>([]);
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [review, setReview] = useState<{ value: GitPatchExport; selectionKey: string } | null>(
    null,
  );
  const [status, setStatus] = useState<"loading" | "ready" | "failed" | "saving" | "finished">(
    "loading",
  );
  const [error, setError] = useState("");
  const [savedPath, setSavedPath] = useState("");
  const [attempt, setAttempt] = useState(0);
  const generation = useRef(0);
  const activeReads = useRef(new Set<string>());
  const alive = useRef(true);
  const contextKey = JSON.stringify([source, baseRevision, targetRevision]);
  const selectionKey = `${contextKey}\0${JSON.stringify([...selected].sort())}`;
  const previewCurrent = review?.selectionKey === selectionKey;
  const ranges = source === "commits" ? { baseRevision, targetRevision } : {};

  useEffect(() => {
    alive.current = true;
    return () => {
      alive.current = false;
      generation.current += 1;
      for (const id of activeReads.current) void cancelGitHistoryOperation(id);
    };
  }, []);

  const read = async (paths: string[], metadataOnly = false) => {
    const id = crypto.randomUUID();
    activeReads.current.add(id);
    try {
      return await exportGitPatch(request.repoPath, source, paths, ranges, id, metadataOnly);
    } finally {
      activeReads.current.delete(id);
    }
  };

  useEffect(() => {
    const token = ++generation.current;
    setStatus("loading");
    setReview(null);
    setError("");
    setFiles([]);
    if (
      source === "commits" &&
      (!baseRevision || !targetRevision || baseRevision === targetRevision)
    ) {
      setError(t("git.patch.distinctCommits"));
      setStatus("failed");
      return;
    }
    void (async () => {
      try {
        const all = await read([], true);
        if (!alive.current || token !== generation.current) return;
        const initial = new Set(
          request.paths
            ? all.files
                .filter(
                  (file) =>
                    request.paths!.includes(file.path) ||
                    (file.originalPath !== null && request.paths!.includes(file.originalPath)),
                )
                .map((file) => file.path)
            : all.files.map((file) => file.path),
        );
        setFiles(all.files);
        setSelected(initial);
        setStatus("ready");
      } catch (failure) {
        if (!alive.current || token !== generation.current) return;
        setError(failure instanceof Error ? failure.message : String(failure));
        setStatus("failed");
      }
    })();
  }, [request, source, baseRevision, targetRevision, attempt]);

  const updatePreview = async () => {
    if (selected.size === 0) return;
    const token = ++generation.current;
    setStatus("loading");
    setError("");
    try {
      const value = await read(
        files
          .filter((file) => selected.has(file.path))
          .flatMap((file) => (file.originalPath ? [file.path, file.originalPath] : [file.path])),
      );
      if (alive.current && token === generation.current) {
        setReview({ value, selectionKey });
        setStatus("ready");
      }
    } catch (failure) {
      if (alive.current && token === generation.current) {
        setError(String(failure));
        setReview(null);
        setStatus("ready");
      }
    }
  };

  const savePatch = async () => {
    if (!review || !previewCurrent || !review.value.patch || status !== "ready") return;
    setStatus("saving");
    try {
      const destination = await save({
        title: t("git.patch.create"),
        defaultPath: `lithe-${new Date().toISOString().replace(/[:.]/g, "-")}.patch`,
        filters: [{ name: "Git patch", extensions: ["patch", "diff"] }],
      });
      if (!alive.current) return;
      if (!destination) {
        setStatus("ready");
        return;
      }
      await writeGitPatchFile(destination, review.value.patch);
      if (alive.current) {
        setSavedPath(destination);
        setStatus("finished");
      }
    } catch (failure) {
      if (alive.current) {
        setError(String(failure));
        setStatus("failed");
      }
    }
  };

  const commitOptions =
    request.commits?.map((commit) => ({
      value: commit.hash,
      label: `${commit.shortHash} ${commit.message}`,
    })) ?? [];
  return (
    <Dialog
      open
      onOpenChange={(isOpen) => {
        if (!isOpen && status !== "saving") onClose(status === "finished");
      }}
    >
      <DialogContent size="lg" className="max-w-3xl" showCloseButton={status !== "saving"}>
        <DialogHeader>
          <DialogTitle>{t("git.patch.create")}</DialogTitle>
          <DialogDescription>{t("git.patch.exportDescription")}</DialogDescription>
        </DialogHeader>
        <div className="min-h-0 space-y-3 overflow-auto px-5 py-4 ui-text-sm">
          {status === "finished" ? (
            <p role="status" className="break-all select-text">
              {t("git.patch.saved", { path: savedPath })}
            </p>
          ) : (
            <>
              {source === "commits" ? (
                <div className="grid grid-cols-2 gap-3">
                  <label className="space-y-1">
                    <span>{t("git.patch.base")}</span>
                    <Select
                      value={baseRevision}
                      options={commitOptions}
                      onChange={setBaseRevision}
                      disabled={status === "saving"}
                    />
                  </label>
                  <label className="space-y-1">
                    <span>{t("git.patch.targetCommit")}</span>
                    <Select
                      value={targetRevision}
                      options={commitOptions}
                      onChange={setTargetRevision}
                      disabled={status === "saving"}
                    />
                  </label>
                </div>
              ) : (
                <Select
                  value={source}
                  onChange={(value) => setSource(value as GitPatchSource)}
                  disabled={status === "saving"}
                  aria-label={t("git.patch.source")}
                  options={(["workingTree", "staged", "unstaged"] as const).map((value) => ({
                    value,
                    label: t(`git.patch.source.${value}`),
                  }))}
                />
              )}
              {files.length > 0 ? (
                <>
                  <div className="flex items-center justify-between">
                    <span>{t("git.patch.selectedFiles", { count: selected.size })}</span>
                    <Button
                      size="xs"
                      onClick={() =>
                        setSelected(
                          selected.size === files.length
                            ? new Set()
                            : new Set(files.map((file) => file.path)),
                        )
                      }
                      disabled={status !== "ready"}
                    >
                      {t(
                        selected.size === files.length
                          ? "git.patch.selectNone"
                          : "git.patch.selectAll",
                      )}
                    </Button>
                  </div>
                  <PatchFileList
                    files={files}
                    selected={selected}
                    onToggle={
                      status === "ready"
                        ? (path, checked) =>
                            setSelected((current) => {
                              const next = new Set(current);
                              if (checked) next.add(path);
                              else next.delete(path);
                              return next;
                            })
                        : undefined
                    }
                  />
                </>
              ) : status === "ready" ? (
                <p>{t("git.patch.noChanges")}</p>
              ) : null}
              {status === "loading" ? <Spinner label={t("git.patch.loading")} showLabel /> : null}
              {error ? (
                <p role="alert" className="whitespace-pre-wrap text-destructive">
                  {error}
                </p>
              ) : null}
              {review && previewCurrent ? (
                <RawPatchPreview patch={review.value.patch} />
              ) : files.length > 0 ? (
                <p>{t("git.patch.previewSelection")}</p>
              ) : null}
            </>
          )}
        </div>
        <DialogFooter>
          <Button onClick={() => onClose(status === "finished")} disabled={status === "saving"}>
            {t(status === "finished" ? "ui.done" : "ui.cancel")}
          </Button>
          {status === "failed" ? (
            <Button onClick={() => setAttempt((value) => value + 1)}>{t("ui.retry")}</Button>
          ) : null}
          {status !== "finished" ? (
            <>
              <Button
                disabled={status !== "ready" || selected.size === 0 || previewCurrent}
                onClick={() => void updatePreview()}
              >
                {t("git.patch.preview")}
              </Button>
              <Button
                variant="accent"
                disabled={
                  status !== "ready" ||
                  !previewCurrent ||
                  !review?.value.patch ||
                  selected.size === 0
                }
                onClick={() => void savePatch()}
              >
                {t(status === "saving" ? "ui.saving" : "git.patch.save")}
              </Button>
            </>
          ) : null}
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

function PatchApplyDialog({
  request,
  onClose,
}: {
  request: GitPatchDialogRequest;
  onClose: (completed: boolean) => void;
}) {
  const { t } = useTranslation();
  const [patch, setPatch] = useState("");
  const [target, setTarget] = useState<GitPatchTarget>("worktree");
  const [preview, setPreview] = useState<GitPatchPreview | null>(null);
  const [status, setStatus] = useState<
    "idle" | "loading" | "ready" | "failed" | "applying" | "finished"
  >("idle");
  const [error, setError] = useState("");
  const [warnings, setWarnings] = useState<GitOperationWarning[]>([]);
  const generation = useRef(0);
  const alive = useRef(true);
  const operationId = useRef<string | null>(null);
  const busy = status === "loading" || status === "applying";

  useEffect(() => {
    alive.current = true;
    return () => {
      alive.current = false;
      generation.current += 1;
      if (operationId.current) void cancelGitHistoryOperation(operationId.current);
    };
  }, []);
  const invalidate = () => {
    generation.current += 1;
    setPreview(null);
    setError("");
    setStatus("idle");
  };
  const report = (failure: unknown) => {
    const message = failure instanceof Error ? failure.message : String(failure);
    setError(message.startsWith("git.patch.") ? t(message) : message);
    setStatus("failed");
  };
  const loadFile = async () => {
    const token = ++generation.current;
    setStatus("loading");
    setPreview(null);
    setError("");
    try {
      const path = await open({
        title: t("git.patch.openFile"),
        multiple: false,
        filters: [{ name: "Git patch", extensions: ["patch", "diff"] }],
      });
      if (!alive.current || token !== generation.current) return;
      if (!path || Array.isArray(path)) {
        setStatus("idle");
        return;
      }
      const value = await readGitPatchFile(path);
      if (alive.current && token === generation.current) {
        setPatch(value);
        setStatus("idle");
      }
    } catch (failure) {
      if (alive.current && token === generation.current) report(failure);
    }
  };
  const check = async () => {
    if (!patch || busy) return;
    const token = ++generation.current;
    setPreview(null);
    setStatus("loading");
    setError("");
    const id = crypto.randomUUID();
    operationId.current = id;
    try {
      if (
        patch.length > GIT_PATCH_MAX_BYTES ||
        new TextEncoder().encode(patch).length > GIT_PATCH_MAX_BYTES
      )
        throw new Error("git.patch.fileTooLarge");
      const value = await previewGitPatch(request.repoPath, patch, target, id);
      if (alive.current && token === generation.current) {
        setPreview(value);
        setStatus("ready");
      }
    } catch (failure) {
      if (alive.current && token === generation.current) report(failure);
    } finally {
      if (operationId.current === id) operationId.current = null;
    }
  };
  const apply = async () => {
    if (status !== "ready" || !preview?.applicable || !preview.expectedState) return;
    setStatus("applying");
    setError("");
    try {
      const value = await applyGitPatch(request.repoPath, patch, target, preview.expectedState);
      if (alive.current) {
        setWarnings(value);
        setStatus("finished");
      }
    } catch (failure) {
      if (alive.current) {
        setPreview(null);
        report(failure);
      }
    }
  };
  return (
    <Dialog
      open
      onOpenChange={(isOpen) => {
        if (!isOpen && status !== "applying") onClose(status === "finished");
      }}
    >
      <DialogContent size="lg" className="max-w-3xl" showCloseButton={status !== "applying"}>
        <DialogHeader>
          <DialogTitle>{t("git.patch.apply")}</DialogTitle>
          <DialogDescription>{t("git.patch.applyDescription")}</DialogDescription>
        </DialogHeader>
        <div className="min-h-0 space-y-3 overflow-auto px-5 py-4 ui-text-sm">
          {status === "finished" ? (
            <div role="status">
              <p>{t("git.patch.applied")}</p>
              {warnings.map((warning, index) => (
                <p
                  key={`${warning.code}:${index}`}
                  className="whitespace-pre-wrap text-git-modified"
                >
                  {warning.message}
                  {warning.details ? `\n${warning.details}` : ""}
                </p>
              ))}
            </div>
          ) : (
            <>
              <Button onClick={() => void loadFile()} disabled={busy}>
                {t("git.patch.openFile")}
              </Button>
              <Select
                value={target}
                disabled={busy}
                onChange={(value) => {
                  invalidate();
                  setTarget(value as GitPatchTarget);
                }}
                aria-label={t("git.patch.destination")}
                options={(["worktree", "indexAndWorktree"] as const).map((value) => ({
                  value,
                  label: t(`git.patch.target.${value}`),
                }))}
              />
              {!preview ? (
                <label className="block space-y-1">
                  <span>{t("git.patch.paste")}</span>
                  <Textarea
                    value={patch.slice(0, PATCH_DISPLAY_CHARACTERS)}
                    readOnly={patch.length > PATCH_DISPLAY_CHARACTERS}
                    onChange={(event) => {
                      invalidate();
                      setPatch(event.target.value);
                    }}
                    rows={9}
                    className="max-h-64 font-mono"
                    disabled={busy}
                  />
                  {patch.length > PATCH_DISPLAY_CHARACTERS ? (
                    <span>{t("git.patch.displayTruncated")}</span>
                  ) : null}
                </label>
              ) : (
                <>
                  <PatchFileList files={preview.files} />
                  <RawPatchPreview patch={patch} />
                  <p
                    role="status"
                    className={
                      preview.applicable
                        ? "text-subtle-foreground"
                        : "whitespace-pre-wrap text-destructive"
                    }
                  >
                    {preview.applicable
                      ? t("git.patch.applicable")
                      : preview.diagnostic || t("git.patch.notApplicable")}
                  </p>
                  <Button size="xs" disabled={busy} onClick={invalidate}>
                    {t("git.patch.editPatch")}
                  </Button>
                </>
              )}
              {status === "loading" ? <Spinner label={t("git.patch.checking")} showLabel /> : null}
              {error ? (
                <p role="alert" className="whitespace-pre-wrap text-destructive">
                  {error}
                </p>
              ) : null}
            </>
          )}
        </div>
        <DialogFooter>
          <Button disabled={status === "applying"} onClick={() => onClose(status === "finished")}>
            {t(status === "finished" ? "ui.done" : "ui.cancel")}
          </Button>
          {status !== "finished" ? (
            <>
              <Button disabled={busy || !patch} onClick={() => void check()}>
                {t("git.patch.check")}
              </Button>
              <Button
                variant="accent"
                disabled={status !== "ready" || !preview?.applicable || !preview.expectedState}
                onClick={() => void apply()}
              >
                {t(status === "applying" ? "git.patch.applying" : "git.patch.confirmApply")}
              </Button>
            </>
          ) : null}
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

export function GitPatchDialogHost() {
  const [request, setRequest] = useState<GitPatchDialogRequest | null>(null);
  const requestRef = useRef<GitPatchDialogRequest | null>(null);
  const workspaceId = useActiveWorkspaceId();
  const selectedRepository = useRepositoryStore((state) => state.activeRepoPath);
  const close = (completed: boolean) => {
    requestRef.current?.resolve(completed);
    requestRef.current = null;
    setRequest(null);
  };
  useEffect(() => {
    const detach = attachGitPatchDialogHost((next) => {
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
  if (!request || !current) return null;
  return request.mode === "export" ? (
    <PatchExportDialog key={request.id} request={request} onClose={close} />
  ) : (
    <PatchApplyDialog key={request.id} request={request} onClose={close} />
  );
}
