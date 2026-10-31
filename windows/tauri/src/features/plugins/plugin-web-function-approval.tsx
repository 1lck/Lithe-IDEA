import { createRoot } from "react-dom/client";
import { LocaleProvider, useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import AppDialog from "@/ui/dialog";
import type { FunctionContext } from "./plugin-function-session";

export interface WebFunctionReview {
  context: FunctionContext;
  executesProjectCode: boolean;
  mayUseNetwork: boolean;
  program: unknown;
  launchPlan: unknown;
}

export interface WebFunctionApproval {
  approve(review: WebFunctionReview, signal: AbortSignal): Promise<boolean>;
  close(): void;
}

/** The page cannot approve itself. This host-owned dialog shows the frozen
 * native program and risk flags before the host listener confirms the receipt. */
export function createWebFunctionApproval(): WebFunctionApproval {
  const element = document.createElement("div");
  document.body.append(element);
  const root = createRoot(element);
  let disposed = false;
  let settle: ((accepted: boolean) => void) | null = null;
  const close = () => {
    if (disposed) return;
    disposed = true;
    settle?.(false);
    settle = null;
    root.unmount();
    element.remove();
  };
  return {
    approve: (review, signal) =>
      new Promise<boolean>((resolve) => {
        settle?.(false);
        settle = (accepted) => {
          settle = null;
          signal.removeEventListener("abort", abort);
          if (!disposed) root.render(null);
          resolve(accepted && !signal.aborted);
        };
        const abort = () => settle?.(false);
        signal.addEventListener("abort", abort, { once: true });
        if (signal.aborted || disposed) abort();
        else
          root.render(
            <LocaleProvider>
              <Review review={review} decide={(accepted) => settle?.(accepted)} />
            </LocaleProvider>,
          );
      }),
    close,
  };
}

function Review({
  review,
  decide,
}: {
  review: WebFunctionReview;
  decide(accepted: boolean): void;
}) {
  const { t } = useTranslation();
  return (
    <AppDialog
      title={t("buildSystems.model.reviewTitle")}
      onClose={() => decide(false)}
      footer={
        <>
          <Button onClick={() => decide(false)}>{t("buildSystems.model.decline")}</Button>
          <Button onClick={() => decide(true)}>{t("buildSystems.run.approve")}</Button>
        </>
      }
    >
      <dl className="ui-text-sm">
        <dt>{t("buildSystems.model.plugin")}</dt>
        <dd className="break-all">{review.context.pluginId}</dd>
        <dt>{t("buildSystems.model.workspace")}</dt>
        <dd className="break-all">{review.context.workspacePath}</dd>
        <dt>{t("buildSystems.model.operation")}</dt>
        <dd className="break-all">
          {review.context.functionId || t("plugins.functions.function")}
        </dd>
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
      <pre className="max-h-48 overflow-auto whitespace-pre-wrap break-all ui-text-sm">
        {JSON.stringify({ program: review.program, launchPlan: review.launchPlan }, null, 2)}
      </pre>
    </AppDialog>
  );
}
