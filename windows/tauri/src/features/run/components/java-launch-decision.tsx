import { Button } from "@/ui/button";
import { WarningIcon } from "@/ui/icons";
import { useTranslation } from "@/i18n/locale-provider";
import type { JavaLaunchDecision } from "../stores/run.store";

interface JavaLaunchDecisionBannerProps {
  decision: JavaLaunchDecision;
  onContinue: () => void;
  onAlwaysContinue: () => void;
  onRebuildIndex: () => void;
  onCancel: () => void;
  onOpenLogs: () => void;
}

/** Presents one paused launch without deciding on the user's behalf. */
export function JavaLaunchDecisionBanner({
  decision,
  onContinue,
  onAlwaysContinue,
  onRebuildIndex,
  onCancel,
  onOpenLogs,
}: JavaLaunchDecisionBannerProps) {
  const { t } = useTranslation();
  const report = decision.failure.report;
  const canRebuildIndex = report?.recovery === "rebuildJavaIndex";
  return (
    <section
      className="space-y-2 border-warning/30 border-b bg-warning/10 px-3 py-2"
      aria-live="polite"
    >
      <div className="flex items-start gap-2">
        <WarningIcon className="mt-0.5 size-3.5 text-warning" />
        <div className="min-w-0 flex-1">
          <div className="font-medium ui-text-sm">{t("run.javaBuildFailedTitle")}</div>
          <div className="text-subtle-foreground ui-text-sm">{decision.failure.message}</div>
          {decision.failure.code === "javaBuildFailed" || report?.builderFailedEarlier ? (
            <div className="mt-1 text-subtle-foreground ui-text-sm">
              {t("run.javaBuildMarkersMayRemain")}
            </div>
          ) : null}
          {report?.markerScope === "workspace" ? (
            <div className="mt-1 text-subtle-foreground ui-text-sm">
              {t("run.javaBuildWorkspaceScope")}
            </div>
          ) : null}
          {report ? (
            <div className="mt-1 text-subtle-foreground ui-text-sm">
              {t("run.javaBuildElapsed", { milliseconds: report.elapsedMilliseconds })}
            </div>
          ) : null}
        </div>
      </div>
      <div className="flex flex-wrap gap-2 pl-5">
        <Button size="xs" variant="accent" onClick={onContinue}>
          {t("run.javaBuildContinue")}
        </Button>
        <Button size="xs" onClick={onAlwaysContinue}>
          {t("run.javaBuildAlwaysContinue")}
        </Button>
        {canRebuildIndex ? (
          <Button size="xs" onClick={onRebuildIndex}>
            {t("run.javaBuildRebuildIndex")}
          </Button>
        ) : null}
        <Button size="xs" variant="ghost" onClick={onOpenLogs}>
          {t("run.javaBuildOpenLogs")}
        </Button>
        <Button size="xs" variant="ghost" onClick={onCancel}>
          {t("run.cancel")}
        </Button>
      </div>
    </section>
  );
}
