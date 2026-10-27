import { useSyncExternalStore } from "react";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import type { VcsRootController } from "./vcs-root-controller";
import type { VcsRoot } from "./vcs-root-types";

const MAX_VISIBLE_STATUS_CHANGES = 500;

/** Provider replies stay in the independent VCS projection. Reading status
 * is explicit and ends its native session before the snapshot is published. */
export function VcsStatusPanel({
  controller,
  root,
}: {
  controller: VcsRootController;
  root: VcsRoot;
}) {
  const { t } = useTranslation();
  const state = useSyncExternalStore(controller.status.subscribe, controller.status.getSnapshot);
  const busy =
    state.phase === "loading" || state.phase === "stopping" || state.phase === "cancelFailed";
  const snapshot = state.snapshot?.rootId === root.id ? state.snapshot : null;
  const error = String(state.error ?? "");
  const failureKey = error.includes("vcs.tool.unavailable")
    ? "vcs.status.toolUnavailable"
    : error.includes("requestTimeout")
      ? "vcs.status.timeout"
      : "vcs.status.unavailable";
  return (
    <div data-testid="vcs-status" className="space-y-1">
      <div className="flex gap-1">
        <Button
          size="xs"
          disabled={busy}
          onClick={() => {
            void controller.status.refresh(root.id);
          }}
        >
          {t("vcs.status.refresh")}
        </Button>
        {busy && (
          <Button
            size="xs"
            disabled={state.phase === "stopping"}
            onClick={() => {
              void controller.status.cancel().catch(() => {});
            }}
          >
            {t(state.phase === "cancelFailed" ? "vcs.status.retryStop" : "vcs.status.stop")}
          </Button>
        )}
      </div>
      {state.phase === "loading" && <p role="status">{t("vcs.status.loading")}</p>}
      {state.phase === "stopping" && <p role="status">{t("vcs.status.stopping")}</p>}
      {state.phase === "cancelFailed" && <p role="alert">{t("vcs.status.cleanupFailed")}</p>}
      {state.phase === "failed" && <p role="alert">{t(failureKey)}</p>}
      {snapshot && (
        <>
          {snapshot.result.changes.length === 0 && <p role="status">{t("vcs.status.empty")}</p>}
          <ul className="max-h-48 overflow-auto" aria-label={t("vcs.status.changes")}>
            {snapshot.result.changes.slice(0, MAX_VISIBLE_STATUS_CHANGES).map((change) => (
              <li key={change.path} className="flex gap-2">
                <span>{t(`vcs.status.kind.${change.status}`)}</span>
                <span className="truncate" title={change.path}>
                  {change.path}
                </span>
              </li>
            ))}
          </ul>
          {snapshot.result.changes.length > MAX_VISIBLE_STATUS_CHANGES && (
            <p role="status">
              {t("vcs.status.visibleLimit", {
                count: MAX_VISIBLE_STATUS_CHANGES,
                total: snapshot.result.changes.length,
              })}
            </p>
          )}
          {snapshot.result.truncated && <p role="status">{t("vcs.status.truncated")}</p>}
        </>
      )}
    </div>
  );
}
