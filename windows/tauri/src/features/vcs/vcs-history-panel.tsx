import { useEffect, useRef, useState, useSyncExternalStore } from "react";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import Select from "@/ui/select";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { createLocalHistoryDiff } from "@/features/local-history/utils/local-history-diff";
import type { VcsRootController } from "./vcs-root-controller";
import type { VcsRoot } from "./vcs-root-types";
import type { VcsBaseContent, VcsHistoryEntry } from "./vcs-query-types";

export function VcsHistoryPanel({
  controller,
  root,
  changes,
}: {
  controller: VcsRootController;
  root: VcsRoot;
  changes: Array<{ path: string; oldPath: string | null; status: string }>;
}) {
  const { t } = useTranslation();
  const state = useSyncExternalStore(controller.query.subscribe, controller.query.getSnapshot);
  useSyncExternalStore(controller.actions.subscribe, controller.actions.getSnapshot);
  const status = useSyncExternalStore(controller.status.subscribe, controller.status.getSnapshot);
  const [compareBusy, setCompareBusy] = useState(false);
  const [selectedPath, setSelectedPath] = useState("");
  const [binaryComparison, setBinaryComparison] = useState(false);
  const lifetime = useRef(0);
  useEffect(() => {
    ++lifetime.current;
    setCompareBusy(false);
    setSelectedPath("");
    setBinaryComparison(false);
    return () => {
      ++lifetime.current;
      controller.query.invalidate();
    };
  }, [controller, root.id]);
  const currentChange =
    changes.find((change) => change.path === selectedPath) ?? changes[0] ?? null;
  const openComparison = (path: string, result: VcsBaseContent) => {
    if (result.binary || result.currentBinary) {
      setBinaryComparison(true);
      return;
    }
    const diff = createLocalHistoryDiff({
      filePath: path,
      oldContent: result.content ?? "",
      newContent: result.currentContent ?? "",
    });
    diff.is_new = result.content === null;
    diff.is_deleted = result.currentContent === null;
    diff.is_renamed = result.path !== result.currentPath;
    diff.old_path = result.path;
    diff.new_path = result.currentPath;
    useBufferStore
      .getState()
      .actions.openBuffer(
        `diff://vcs-base/${encodeURIComponent(controller.scope.incarnation)}/${encodeURIComponent(root.id)}/${encodeURIComponent(path)}`,
        t("vcs.history.compareTitle", { file: path }),
        "",
        false,
        true,
        true,
        diff,
      );
  };
  const compare = async () => {
    if (compareBusy || !currentChange) return;
    const epoch = lifetime.current;
    const path = currentChange.path;
    const basePath = currentChange.status === "renamed" ? (currentChange.oldPath ?? path) : path;
    setCompareBusy(true);
    setBinaryComparison(false);
    try {
      await controller.query.compare(root.id, basePath, path, (result) => {
        if (lifetime.current === epoch) openComparison(path, result);
      });
    } finally {
      if (lifetime.current === epoch) setCompareBusy(false);
    }
  };
  const entries: VcsHistoryEntry[] = state.rootId === root.id ? state.entries : [];
  const busy =
    state.phase === "loading" || state.phase === "stopping" || state.phase === "cancelFailed";
  const readBlocked =
    controller.actions.busy ||
    busy ||
    status.phase === "loading" ||
    status.phase === "stopping" ||
    status.phase === "cancelFailed";
  return (
    <section className="space-y-1" data-testid="vcs-history">
      {changes.length > 0 && (
        <Select
          size="xs"
          value={currentChange?.path ?? ""}
          disabled={readBlocked}
          aria-label={t("vcs.status.changes")}
          options={changes.map((change) => ({ value: change.path, label: change.path }))}
          onChange={(path) => {
            controller.query.invalidate();
            setSelectedPath(path);
            setBinaryComparison(false);
          }}
        />
      )}
      <div className="flex gap-1">
        <Button
          size="xs"
          disabled={readBlocked}
          onClick={() => void controller.query.history(root.id)}
        >
          {t("vcs.history.read")}
        </Button>
        {currentChange && (
          <Button
            size="xs"
            disabled={readBlocked}
            onClick={() => void controller.query.history(root.id, currentChange.path)}
          >
            {t("vcs.history.readFile")}
          </Button>
        )}
        {currentChange && (
          <Button size="xs" disabled={readBlocked || compareBusy} onClick={() => void compare()}>
            {t("vcs.history.compareBase")}
          </Button>
        )}
        {busy && (
          <Button
            size="xs"
            disabled={state.phase === "stopping"}
            onClick={() => void controller.query.cancel().catch(() => {})}
          >
            {t(state.phase === "cancelFailed" ? "vcs.status.retryStop" : "vcs.status.stop")}
          </Button>
        )}
      </div>
      {state.phase === "loading" && <p role="status">{t("vcs.history.loading")}</p>}
      {state.phase === "stopping" && <p role="status">{t("vcs.history.stopping")}</p>}
      {state.phase === "cancelFailed" && <p role="alert">{t("vcs.history.cleanupFailed")}</p>}
      {state.phase === "failed" && <p role="alert">{t("vcs.history.failed")}</p>}
      {binaryComparison && (
        <p role="status">{t("git.binaryDiffDescription", { name: currentChange?.path ?? "" })}</p>
      )}
      {entries.length > 0 && (
        <ol aria-label={t("vcs.history.entries")} className="max-h-40 overflow-auto">
          {entries.map((entry, index) => (
            <li key={`${entry.revision.id}:${index}`} className="flex gap-2 truncate">
              <span className="shrink-0">{entry.revision.display}</span>
              <span className="truncate" title={entry.message}>
                {entry.message || t("vcs.history.noMessage")}
              </span>
            </li>
          ))}
        </ol>
      )}
      {state.nextCursor && !state.limited && (
        <Button size="xs" disabled={readBlocked} onClick={() => void controller.query.more()}>
          {t("vcs.history.more")}
        </Button>
      )}
      {state.limited && <p role="status">{t("vcs.history.limit")}</p>}
      {state.phase === "ready" && state.rootId === root.id && entries.length === 0 && (
        <p role="status">{t("vcs.history.empty")}</p>
      )}
    </section>
  );
}
