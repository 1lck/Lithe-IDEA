import { useEffect, useRef, useState } from "react";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import AppDialog from "@/ui/dialog";
import { Spinner } from "@/ui/spinner";
import {
  BuildModelCancellationError,
  cancelBuildModel,
  loadBuildModel,
} from "../build-systems-service";
import type { BuildInstanceView, BuildModelReview } from "../build-systems-types";

/** Uses only the existing model IPC; execution/output ports are separate owners. */
export interface BuildModelService {
  load: typeof loadBuildModel;
  cancel: typeof cancelBuildModel;
}
export const buildModelService: BuildModelService = {
  load: loadBuildModel,
  cancel: cancelBuildModel,
};

type Phase =
  | "idle"
  | "preparing"
  | "review"
  | "loading"
  | "stopping"
  | "ready"
  | "declined"
  | "stopped"
  | "failed"
  | "cancelFailed";
interface Attempt {
  controller: AbortController;
  review: BuildModelReview | null;
  decide: ((accepted: boolean) => void) | null;
  declined: boolean;
  stopping: boolean;
  cancelPending: boolean;
  cancelFailed: boolean;
}

/** One mounted instance owns consent and its AbortSignal. The parent keys it
 * by workspace, registry generation and instance, so navigation disposes the
 * old flow before another instance can receive a result or an approval. */
export default function BuildModelControls({
  instance,
  disabled,
  service = buildModelService,
}: {
  instance: BuildInstanceView;
  disabled: boolean;
  service?: BuildModelService;
}) {
  const { t } = useTranslation();
  const [phase, setPhase] = useState<Phase>("idle");
  const [review, setReview] = useState<BuildModelReview | null>(null);
  const [error, setError] = useState("");
  const [stderr, setStderr] = useState("");
  const current = useRef<Attempt | null>(null);
  const mounted = useRef(true);
  useEffect(() => {
    mounted.current = true;
    return () => {
      mounted.current = false;
      const attempt = current.current;
      current.current = null;
      attempt?.controller.abort();
      attempt?.decide?.(false);
    };
  }, [service]);
  const owns = (attempt: Attempt) => mounted.current && current.current === attempt;

  const start = () => {
    if (disabled || current.current) return;
    const attempt: Attempt = {
      controller: new AbortController(),
      review: null,
      decide: null,
      declined: false,
      stopping: false,
      cancelPending: false,
      cancelFailed: false,
    };
    current.current = attempt;
    setPhase("preparing");
    setError("");
    setStderr("");
    void Promise.resolve()
      .then(() =>
        service.load(
          instance.pluginID,
          instance.buildSystemID,
          instance.root,
          (nativeReview, signal) =>
            new Promise<boolean>((resolve) => {
              if (!owns(attempt) || signal.aborted || attempt.controller.signal.aborted) {
                resolve(false);
                return;
              }
              attempt.review = nativeReview;
              let decided = false;
              const decide = (accepted: boolean) => {
                if (decided) return;
                decided = true;
                signal.removeEventListener("abort", abort);
                attempt.controller.signal.removeEventListener("abort", abort);
                attempt.decide = null;
                if (owns(attempt)) {
                  setReview(null);
                  setPhase(accepted ? "loading" : "stopping");
                }
                resolve(accepted);
              };
              const abort = () => {
                attempt.stopping = true;
                decide(false);
              };
              attempt.decide = decide;
              signal.addEventListener("abort", abort, { once: true });
              attempt.controller.signal.addEventListener("abort", abort, { once: true });
              setReview(nativeReview);
              setPhase("review");
            }),
          {},
          {
            signal: attempt.controller.signal,
            onPrepared: (prepared) => {
              if (owns(attempt)) attempt.review = prepared;
            },
          },
        ),
      )
      .then(
        (result) => {
          if (!owns(attempt) || attempt.cancelPending) return;
          if (attempt.cancelFailed) return;
          current.current = null;
          setReview(null);
          if (attempt.stopping || !result) setPhase(attempt.declined ? "declined" : "stopped");
          else {
            setPhase("ready");
            setStderr(result.stderr);
          }
        },
        (failure: unknown) => {
          if (!owns(attempt)) return;
          setReview(null);
          setError(failure instanceof Error ? failure.message : String(failure));
          if (failure instanceof BuildModelCancellationError || attempt.stopping)
            setPhase("cancelFailed");
          else {
            current.current = null;
            setPhase("failed");
          }
        },
      );
  };
  const cancel = () => {
    const attempt = current.current;
    if (!attempt || attempt.cancelPending) return;
    attempt.stopping = true;
    attempt.cancelFailed = false;
    setError("");
    setPhase("stopping");
    setReview(null);
    if (!attempt.review) {
      attempt.controller.abort();
      return;
    }
    attempt.cancelPending = true;
    // Native cancel waits for cleanup. A failed request keeps Stop retryable;
    // the load's late result never claims success for this stopping attempt.
    void Promise.resolve()
      .then(() => service.cancel(attempt.review!.operationId))
      .then(
        () => {
          attempt.cancelPending = false;
          if (!owns(attempt)) return;
          attempt.controller.abort();
          attempt.decide?.(false);
          current.current = null;
          setError("");
          setPhase("stopped");
        },
        (failure: unknown) => {
          attempt.cancelPending = false;
          if (!owns(attempt)) return;
          attempt.cancelFailed = true;
          setError(failure instanceof Error ? failure.message : String(failure));
          setPhase("cancelFailed");
        },
      );
  };
  const decide = (accepted: boolean) => {
    const attempt = current.current;
    if (!attempt) return;
    attempt.declined = !accepted;
    attempt.decide?.(accepted);
  };
  const busy = ["preparing", "review", "loading", "stopping", "cancelFailed"].includes(phase);
  return (
    <section className="mb-3 min-w-0 space-y-2" aria-label={t("buildSystems.model.title")}>
      <div className="flex flex-wrap items-center gap-2">
        <Button type="button" size="sm" disabled={disabled || busy} onClick={start}>
          {instance.model ? t("buildSystems.model.reload") : t("buildSystems.model.load")}
        </Button>
        {busy && (
          <Button
            type="button"
            variant="ghost"
            size="sm"
            disabled={phase === "stopping"}
            onClick={cancel}
          >
            {phase === "cancelFailed"
              ? t("buildSystems.model.retryCancel")
              : t("buildSystems.model.cancel")}
          </Button>
        )}
        {["preparing", "loading", "stopping"].includes(phase) && <Spinner className="size-3.5" />}
        {phase !== "idle" && (
          <span role="status" className="text-xs text-muted-foreground">
            {t(`buildSystems.model.phase.${phase}`)}
          </span>
        )}
      </div>
      {error && (
        <p role="alert" className="break-words text-xs text-destructive">
          {t(
            phase === "cancelFailed"
              ? "buildSystems.model.cancelFailed"
              : "buildSystems.model.failed",
            { message: error },
          )}
        </p>
      )}
      {stderr && (
        <pre
          className="max-h-32 overflow-auto whitespace-pre-wrap break-words text-xs text-warning"
          aria-label={t("buildSystems.model.stderr")}
        >
          {stderr}
        </pre>
      )}
      {review && (
        <AppDialog
          title={t("buildSystems.model.reviewTitle")}
          size="sm"
          onClose={() => decide(false)}
          footer={
            <>
              <Button type="button" onClick={() => decide(false)}>
                {t("buildSystems.model.decline")}
              </Button>
              <Button type="button" variant="accent" onClick={() => decide(true)}>
                {t("buildSystems.model.approve")}
              </Button>
            </>
          }
        >
          <dl className="grid min-w-0 grid-cols-[auto_minmax(0,1fr)] gap-x-3 gap-y-2 text-xs">
            <dt>{t("buildSystems.model.plugin")}</dt>
            <dd className="break-all">{review.pluginId}</dd>
            <dt>{t("buildSystems.model.buildSystem")}</dt>
            <dd className="break-all">{review.buildSystemId}</dd>
            <dt>{t("buildSystems.model.workspace")}</dt>
            <dd className="break-all">{review.workspaceRoot}</dd>
            <dt>{t("buildSystems.model.instance")}</dt>
            <dd className="break-all">{review.root}</dd>
            <dt>{t("buildSystems.model.operation")}</dt>
            <dd className="break-all">{review.operationId}</dd>
            <dt>{t("buildSystems.model.generation")}</dt>
            <dd>{review.generation}</dd>
          </dl>
          <p className="mt-3 text-xs text-warning">
            {t(
              review.executesProjectCode
                ? "buildSystems.model.projectCode"
                : "buildSystems.model.noProjectCode",
            )}
          </p>
          <p className="mt-2 text-xs text-warning">
            {t(
              review.mayUseNetwork ? "buildSystems.model.network" : "buildSystems.model.noNetwork",
            )}
          </p>
        </AppDialog>
      )}
    </section>
  );
}
