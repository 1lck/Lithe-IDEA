import { useTranslation } from "@/i18n/locale-provider";
import { CheckCircleIcon, XCircleIcon } from "@/ui/icons";
import { cn } from "@/utils/cn";
import type { BuildTestResults } from "../build-output-types";

/**
 * One-line summary of a decoded test run: the pass/fail verdict and the
 * passed, failed (including errored), and skipped counts. Statuses come from
 * Core's aggregation; the panel adds no parsing of its own.
 */
export default function BuildOutputTestsSummary({
  results,
  dropped = 0,
}: {
  results: BuildTestResults;
  dropped?: number;
}) {
  const { t } = useTranslation();
  const failed = results.summary.failed + results.summary.errors;
  return (
    <div
      className="flex shrink-0 flex-wrap items-center gap-x-3 gap-y-0.5 border-b border-border px-2 py-1 ui-text-sm"
      data-slot="build-output-tests"
      role="status"
    >
      <span
        className={cn(
          "inline-flex items-center gap-1 font-medium",
          results.success ? "text-success" : "text-destructive",
        )}
      >
        {results.success ? (
          <CheckCircleIcon className="size-3.5 shrink-0" />
        ) : (
          <XCircleIcon className="size-3.5 shrink-0" />
        )}
        {results.success ? t("buildOutput.testsPassed") : t("buildOutput.testsFailed")}
      </span>
      <span className="text-muted-foreground">
        {t("buildOutput.testsPassedCount", { count: results.summary.passed })}
      </span>
      {failed > 0 && (
        <span className="text-destructive">
          {t("buildOutput.testsFailedCount", { count: failed })}
        </span>
      )}
      {results.summary.skipped > 0 && (
        <span className="text-muted-foreground">
          {t("buildOutput.testsSkippedCount", { count: results.summary.skipped })}
        </span>
      )}
      {dropped > 0 && (
        <span className="text-muted-foreground">
          {t("buildOutput.testsTruncated", { count: dropped })}
        </span>
      )}
    </div>
  );
}
