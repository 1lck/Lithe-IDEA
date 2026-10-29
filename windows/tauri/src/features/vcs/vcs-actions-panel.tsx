import { useEffect, useState, useSyncExternalStore } from "react";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import { Checkbox } from "@/ui/checkbox";
import Textarea from "@/ui/textarea";
import AppDialog from "@/ui/dialog";
import type { VcsRootController } from "./vcs-root-controller";
import type { VcsRoot, VcsStatusSnapshot } from "./vcs-root-types";
import { isConflict, permitsWholeCopy, permitsFileOperation } from "./vcs-action-types";

export const MAX_VISIBLE_STATUS_CHANGES = 500;
export function VcsActionsPanel({
  controller,
  root,
  snapshot,
  readBusy,
}: {
  controller: VcsRootController;
  root: VcsRoot;
  snapshot: VcsStatusSnapshot | null;
  readBusy: boolean;
}) {
  const { t } = useTranslation();
  const state = useSyncExternalStore(controller.actions.subscribe, controller.actions.getSnapshot);
  const [selection, setSelection] = useState<string[]>([]);
  const [message, setMessage] = useState("");
  useEffect(() => {
    setSelection([]);
    setMessage("");
  }, [snapshot]);
  useEffect(
    () => () => {
      controller.actions.invalidate();
    },
    [controller, root.id],
  );
  const busy = controller.actions.busy;
  const changes = snapshot?.result.changes ?? [];
  const canWrite = !!snapshot && !snapshot.result.truncated && !readBusy && !busy;
  const capabilities = snapshot?.capabilities ?? {};
  const wholeCopy = permitsWholeCopy(controller.getSnapshot().snapshot, root.id);
  const review = state.rootId === root.id ? state.review : null;
  const error = String(state.error ?? "");
  const code = [
    "vcs.authentication.failed",
    "vcs.conflict",
    "vcs.outOfDate",
    "vcs.tool.unavailable",
    "vcs.workingCopy.locked",
    "vcs.workingCopy.unsupported",
    "vcs.capability.unsupported",
    "vcs.provider.pathUnavailable",
    "requestTimeout",
    "requestCancelled",
  ].find((code) => error.includes(code));
  return (
    <section className="space-y-1" data-testid="vcs-actions">
      {snapshot && (
        <>
          <ul className="max-h-48 overflow-auto" aria-label={t("vcs.status.changes")}>
            {changes.slice(0, MAX_VISIBLE_STATUS_CHANGES).map((change) => (
              <li key={change.path} className="flex items-center gap-2">
                <Checkbox
                  aria-label={change.path}
                  checked={selection.includes(change.path)}
                  disabled={!canWrite || change.status === "ignored"}
                  onCheckedChange={(checked) =>
                    setSelection((old) =>
                      checked ? [...old, change.path] : old.filter((path) => path !== change.path),
                    )
                  }
                />
                <span>{t(`vcs.status.kind.${change.status}`)}</span>
                <span className="truncate" title={change.path}>
                  {change.oldPath ? `${change.oldPath} → ` : ""}
                  {change.path}
                </span>
              </li>
            ))}
          </ul>
          {capabilities.checkin === 1 && (
            <>
              <Textarea
                aria-label={t("vcs.actions.message")}
                value={message}
                disabled={!canWrite}
                onChange={(event) => setMessage(event.target.value)}
              />
              <Button
                size="xs"
                disabled={!canWrite || !selection.length || !message.trim()}
                onClick={() =>
                  controller.actions.prepare(snapshot, {
                    operation: "checkin",
                    paths: selection,
                    message,
                  })
                }
              >
                {t(capabilities.push === 1 ? "vcs.actions.checkin" : "vcs.actions.checkinRemote")}
              </Button>
            </>
          )}
          {capabilities.rollback === 1 && (
            <Button
              size="xs"
              disabled={
                !canWrite ||
                !selection.length ||
                selection.some(
                  (path) =>
                    changes.find((change) => change.path === path)?.status === "unversioned",
                )
              }
              onClick={() =>
                controller.actions.prepare(snapshot, {
                  operation: "rollback",
                  paths: selection,
                })
              }
            >
              {t("vcs.actions.rollback")}
            </Button>
          )}
          {capabilities.conflicts === 1 && (
            <Button
              size="xs"
              disabled={
                !canWrite ||
                !selection.length ||
                selection.some((path) => {
                  const change = changes.find((change) => change.path === path);
                  return !change || !isConflict(change);
                })
              }
              onClick={() =>
                controller.actions.prepare(snapshot, {
                  operation: "resolve",
                  paths: selection,
                })
              }
            >
              {t("vcs.actions.resolve")}
            </Button>
          )}
          {capabilities.fileOperations === 1 &&
            (["add", "delete"] as const).map((operation) => (
              <Button
                key={operation}
                size="xs"
                disabled={
                  !canWrite ||
                  !selection.length ||
                  selection.some((path) => {
                    const change = changes.find((change) => change.path === path);
                    return !change || !permitsFileOperation(change, operation);
                  })
                }
                onClick={() =>
                  controller.actions.prepare(snapshot, { operation, paths: selection })
                }
              >
                {t(`vcs.actions.${operation}`)}
              </Button>
            ))}
          {(["update", "cleanup"] as const).map(
            (operation) =>
              capabilities[operation] === 1 && (
                <Button
                  key={operation}
                  size="xs"
                  disabled={!canWrite || !wholeCopy}
                  onClick={() => controller.actions.prepare(snapshot, { operation })}
                >
                  {t(`vcs.actions.${operation}`)}
                </Button>
              ),
          )}
        </>
      )}
      {state.rootId === root.id && (
        <>
          {["running", "stopping", "cancelFailed"].includes(state.phase) && (
            <>
              <p role={state.phase === "cancelFailed" ? "alert" : "status"}>
                {t(
                  state.phase === "cancelFailed"
                    ? "vcs.status.cleanupFailed"
                    : "vcs.actions.running",
                )}
              </p>
              <Button
                size="xs"
                disabled={state.phase === "stopping"}
                onClick={() => {
                  void controller.actions.cancel().catch(() => {});
                }}
              >
                {t(state.phase === "cancelFailed" ? "vcs.status.retryStop" : "vcs.status.stop")}
              </Button>
            </>
          )}
          {(state.phase === "unknown" || state.phase === "cancelFailed") && (
            <p role="alert">{t("vcs.actions.unknown")}</p>
          )}
          {(state.phase === "unknown" || state.phase === "failed") && (
            <p role="alert">{t(code ? `vcs.actions.error.${code}` : "vcs.status.unavailable")}</p>
          )}
          {state.phase === "completed" && (
            <p role="status">
              {t("vcs.actions.completed")}
              {state.result?.revision?.display ? ` ${state.result.revision.display}` : ""}
              {!!state.result?.conflicts?.length &&
                t("vcs.actions.conflicts", {
                  count: state.result.conflicts.length,
                })}
            </p>
          )}
        </>
      )}
      {review && (
        <AppDialog
          title={t(`vcs.actions.${review.action.operation}`)}
          onClose={() => {
            void controller.actions.cancel();
          }}
          footer={
            <>
              <Button
                onClick={() => {
                  void controller.actions.cancel();
                }}
              >
                {t("vcs.actions.cancel")}
              </Button>
              <Button
                onClick={() => {
                  void controller.actions.confirm();
                }}
              >
                {t("vcs.actions.confirm")}
              </Button>
            </>
          }
        >
          <p className="break-all">{review.rootPath}</p>
          <p>
            {review.action.operation === "update" || review.action.operation === "cleanup"
              ? t("vcs.actions.wholeCopy")
              : t("vcs.actions.count", { count: review.paths.length })}
          </p>
          <ul className="max-h-48 overflow-auto">
            {review.paths.map((path) => (
              <li key={path} className="break-all">
                {path}
              </li>
            ))}
          </ul>
          {review.action.operation === "checkin" && (
            <pre className="whitespace-pre-wrap break-all">{review.action.message}</pre>
          )}
          <p>{t(`vcs.actions.risk.${review.action.operation}`)}</p>
        </AppDialog>
      )}
    </section>
  );
}
