import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import { Spinner } from "@/ui/spinner";
import { dismissStartupFeedback, useStartupFeedback } from "./startup-feedback.store";
import { STARTUP_FADE_OUT_DURATION_MS, startupStageLabelKey } from "./startup-stages";

/**
 * Startup animation layer.
 *
 * The layer is painted above the workbench while the product is starting. It
 * shows the brand logo and the phase the product is working on, and it keeps a
 * failed startup on screen with the reason and a way to continue.
 *
 * The wording comes from the shared startup feedback contract, so both
 * products describe the same phase with the same sentence.
 */
export function StartupAnimationLayer() {
  const { t } = useTranslation();
  const feedback = useStartupFeedback();

  if (!feedback.visible) return null;

  const failed = feedback.outcome === "failed";

  return (
    <div
      role="status"
      aria-live="polite"
      aria-label={t(startupStageLabelKey(feedback.stage))}
      data-testid="startup-animation-layer"
      data-startup-outcome={feedback.outcome}
      className="fixed inset-0 z-50 flex flex-col items-center justify-center gap-6 bg-background transition-opacity duration-150"
      style={{
        opacity: feedback.fading ? 0 : 1,
        transitionDuration: `${STARTUP_FADE_OUT_DURATION_MS}ms`,
      }}
    >
      <img src="/logo.png" alt="" className="size-16 rounded-2xl" />
      {failed ? (
        <div className="flex max-w-md flex-col items-center gap-3 px-6 text-center">
          <div className="ui-text-base font-medium text-foreground">
            {t("startup.failure.title")}
          </div>
          <div className="ui-text-sm text-subtle-foreground">
            {t(startupStageLabelKey(feedback.stage))}
          </div>
          {feedback.failureMessage ? (
            <p className="ui-text-sm text-subtle-foreground">{feedback.failureMessage}</p>
          ) : null}
          <Button type="button" variant="default" size="sm" onClick={dismissStartupFeedback}>
            {t("startup.failure.continue")}
          </Button>
        </div>
      ) : (
        <div className="flex items-center gap-2.5">
          <Spinner className="size-4 text-subtle-foreground" />
          <span className="ui-text-sm text-subtle-foreground">
            {t(startupStageLabelKey(feedback.stage))}
          </span>
        </div>
      )}
    </div>
  );
}
