import { createRoot } from "react-dom/client";
import { useState, useSyncExternalStore } from "react";
import { LocaleProvider, useTranslation } from "@/i18n/locale-provider";
import AppDialog from "@/ui/dialog";
import { Button } from "@/ui/button";
import BuildOutputPane from "@/features/build-systems/output/components/build-output-pane";
import BuildProviderReviewDetails from "@/features/build-systems/components/build-provider-review";
import type { BuildModelReview } from "@/features/build-systems/build-systems-types";
import type { BuildRunSession } from "@/features/build-systems/build-run-session";

export interface WebBuildApproval {
  approve(review: BuildModelReview, programs: unknown[], signal: AbortSignal): Promise<boolean>;
  show(session: BuildRunSession): void;
  failed(error: string, retry: () => Promise<void>): void;
  close(): void;
}
/** Existing dialog, locale, cancellation and output controls; this presenter
 * owns no build facts or process state. Failed cleanup leaves Retry visible. */
export function createWebBuildApproval(): WebBuildApproval {
  const element = document.createElement("div");
  document.body.append(element);
  const root = createRoot(element);
  let disposed = false;
  let decline: (() => void) | null = null;
  const close = () => {
    if (disposed) return;
    decline?.();
    disposed = true;
    root.unmount();
    element.remove();
  };
  return {
    approve: (review, programs, signal) =>
      new Promise<boolean>((resolve) => {
        decline?.();
        let decided = false;
        const decide = (accepted: boolean) => {
          if (decided) return;
          decided = true;
          decline = null;
          signal.removeEventListener("abort", abort);
          if (!disposed) root.render(null);
          resolve(accepted && !signal.aborted);
        };
        const abort = () => decide(false);
        decline = abort;
        signal.addEventListener("abort", abort, { once: true });
        if (signal.aborted) abort();
        else if (!disposed)
          root.render(
            <LocaleProvider>
              <Review review={review} programs={programs} decide={decide} />
            </LocaleProvider>,
          );
        else decide(false);
      }),
    show: (session) => {
      decline?.();
      if (!disposed)
        root.render(
          <LocaleProvider>
            <Output session={session} close={close} />
          </LocaleProvider>,
        );
    },
    failed: (error, retry) => {
      decline?.();
      if (!disposed)
        root.render(
          <LocaleProvider>
            <Cleanup
              error={error}
              retry={async () => {
                await retry();
                close();
              }}
            />
          </LocaleProvider>,
        );
    },
    close,
  };
}
function Cleanup({ error, retry }: { error: string; retry(): Promise<void> }) {
  const { t } = useTranslation();
  const [failure, setFailure] = useState(error);
  const [busy, setBusy] = useState(false);
  const retryCleanup = async () => {
    setBusy(true);
    try {
      await retry();
    } catch (error) {
      setFailure(String(error));
    } finally {
      setBusy(false);
    }
  };
  return (
    <AppDialog
      title={t("buildSystems.model.reviewTitle")}
      onClose={() => {}}
      footer={
        <Button
          disabled={busy}
          onClick={() => {
            void retryCleanup();
          }}
        >
          {t("buildSystems.model.retryCancel")}
        </Button>
      }
    >
      <p role="alert">{t("buildSystems.model.cancelFailed", { message: failure })}</p>
    </AppDialog>
  );
}
function Review({
  review,
  programs,
  decide,
}: {
  review: BuildModelReview;
  programs: unknown[];
  decide(accepted: boolean): void;
}) {
  const { t } = useTranslation();
  return (
    <AppDialog
      title={t("buildSystems.run.review")}
      onClose={() => decide(false)}
      footer={
        <>
          <Button onClick={() => decide(false)}>{t("buildSystems.model.decline")}</Button>
          <Button onClick={() => decide(true)}>{t("buildSystems.run.approve")}</Button>
        </>
      }
    >
      <dl>
        {(
          [
            ["plugin", review.pluginId],
            ["buildSystem", review.buildSystemId],
            ["workspace", review.workspaceRoot],
            ["instance", review.root],
            ["operation", review.operationId],
            ["generation", review.generation],
          ] as const
        ).map(([key, value]) => (
          <div key={key}>
            <dt>{t(`buildSystems.model.${key}`)}</dt>
            <dd className="break-all">{value}</dd>
          </div>
        ))}
      </dl>
      <p>
        {t(
          review.executesProjectCode
            ? "buildSystems.model.projectCode"
            : "buildSystems.model.noProjectCode",
        )}
      </p>
      <p>
        {t(review.mayUseNetwork ? "buildSystems.model.network" : "buildSystems.model.noNetwork")}
      </p>
      <p>{t("buildSystems.run.programs")}</p>
      <pre className="max-h-48 overflow-auto whitespace-pre-wrap break-all">
        {JSON.stringify(programs, null, 2)}
      </pre>
      {review.provider && <BuildProviderReviewDetails review={review.provider} />}
    </AppDialog>
  );
}
function Output({ session, close }: { session: BuildRunSession; close(): void }) {
  const { t } = useTranslation();
  const state = useSyncExternalStore(session.subscribe, session.getSnapshot);
  const busy = !["ended", "failed", "idle"].includes(state.phase);
  return (
    <AppDialog
      title={t("buildOutput.title")}
      size="lg"
      onClose={() => {
        if (busy) void session.cancel().catch(() => {});
        else close();
      }}
      footer={
        <Button
          onClick={() => {
            if (busy) void session.cancel().catch(() => {});
            else close();
          }}
        >
          {t(
            busy
              ? state.phase === "cancelFailed"
                ? "buildSystems.model.retryCancel"
                : "buildSystems.run.cancel"
              : "buildSystems.close",
          )}
        </Button>
      }
    >
      {state.error && (
        <p role="alert">
          {t(
            state.phase === "cancelFailed"
              ? "buildSystems.model.cancelFailed"
              : "buildSystems.run.failed",
            { message: state.error },
          )}
        </p>
      )}
      <div className="h-80">
        <BuildOutputPane sessionId={session.sessionId} port={session.port} managedEvents />
      </div>
    </AppDialog>
  );
}
