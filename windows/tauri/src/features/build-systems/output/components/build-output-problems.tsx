import { useTranslation } from "@/i18n/locale-provider";
import { InfoIcon, WarningIcon, XCircleIcon } from "@/ui/icons";
import { cn } from "@/utils/cn";
import { isSourceCoordinate, resolveWorkspaceSourcePath } from "../build-output-path";
import type { BuildDiagnostic, BuildTestCase } from "../build-output-types";

/** Problem rows rendered per pass; the remainder collapses into one notice. */
export const MAX_PROBLEM_ROWS = 200;

/** A diagnostic or failed test case with its resolved reveal target. */
interface ProblemRow {
  key: string;
  icon: "error" | "warning" | "info";
  title: string;
  message: string;
  /** Absolute path when the location is a legal workspace file, else null. */
  targetPath: string | null;
  line: number;
  column?: number;
}

function diagnosticRow(
  diagnostic: BuildDiagnostic,
  index: number,
  workspaceRoot: string,
): ProblemRow {
  return {
    key: `d${index}`,
    icon:
      diagnostic.severity === "error"
        ? "error"
        : diagnostic.severity === "warning"
          ? "warning"
          : "info",
    title: diagnostic.column
      ? `${diagnostic.path}:${diagnostic.line}:${diagnostic.column}`
      : `${diagnostic.path}:${diagnostic.line}`,
    message: diagnostic.message,
    targetPath:
      isSourceCoordinate(diagnostic.line) &&
      (diagnostic.column == null || isSourceCoordinate(diagnostic.column))
        ? resolveWorkspaceSourcePath(workspaceRoot, diagnostic.path)
        : null,
    line: diagnostic.line,
    column: diagnostic.column ?? undefined,
  };
}

function failedTestRow(test: BuildTestCase, index: number, workspaceRoot: string): ProblemRow {
  return {
    key: `t${index}`,
    icon: "error",
    title: `${test.suite} › ${test.case}`,
    message: test.message ?? "",
    // Core reports optional locations; only a real one becomes a link.
    targetPath:
      test.path && isSourceCoordinate(test.line)
        ? resolveWorkspaceSourcePath(workspaceRoot, test.path)
        : null,
    line: test.line ?? 1,
  };
}

/**
 * Problem list of one build run: Core-decoded diagnostics plus failed and
 * errored test cases, in output order. Rows navigate through the injected
 * reveal action only when their reported location is a legal workspace-
 * relative path; every other location stays plain text and never becomes a
 * link, mirroring the macOS Build Output guard.
 */
export default function BuildOutputProblems({
  diagnostics,
  failedTests,
  diagnosticsDropped,
  workspaceRoot,
  onReveal,
}: {
  diagnostics: BuildDiagnostic[];
  failedTests: BuildTestCase[];
  diagnosticsDropped: number;
  workspaceRoot: string;
  onReveal: (path: string, line: number, column?: number) => void;
}) {
  const { t } = useTranslation();
  const rows: ProblemRow[] = [
    ...diagnostics.map((diagnostic, index) => diagnosticRow(diagnostic, index, workspaceRoot)),
    ...failedTests.map((test, index) => failedTestRow(test, index, workspaceRoot)),
  ];
  const visible = rows.slice(0, MAX_PROBLEM_ROWS);
  const hidden = rows.length - visible.length;

  return (
    <div
      className="max-h-[132px] shrink-0 overflow-y-auto border-b border-border bg-surface/60 py-1"
      data-slot="build-output-problems"
    >
      {visible.map((row) => {
        const icon =
          row.icon === "error" ? (
            <XCircleIcon className="mt-0.5 size-3.5 shrink-0 text-destructive" />
          ) : row.icon === "warning" ? (
            <WarningIcon className="mt-0.5 size-3.5 shrink-0 text-warning" />
          ) : (
            <InfoIcon className="mt-0.5 size-3.5 shrink-0 text-muted-foreground" />
          );
        const body = (
          <>
            {icon}
            <span className="min-w-0 flex-1">
              <span className="block truncate font-medium" title={row.title}>
                {row.title}
              </span>
              {row.message && (
                <span className="block whitespace-pre-wrap break-words text-muted-foreground">
                  {row.message}
                </span>
              )}
            </span>
          </>
        );
        return row.targetPath ? (
          <button
            key={row.key}
            type="button"
            className={cn(
              "flex w-full items-start gap-1.5 px-2 py-1 text-left ui-text-sm",
              "rounded-sm hover:bg-accent focus-visible:outline-2 focus-visible:outline-offset-[-2px] focus-visible:outline-primary",
            )}
            onClick={() => onReveal(row.targetPath!, row.line, row.column)}
          >
            {body}
          </button>
        ) : (
          <div
            key={row.key}
            className="flex w-full items-start gap-1.5 px-2 py-1 text-left ui-text-sm"
          >
            {body}
          </div>
        );
      })}
      {(hidden > 0 || diagnosticsDropped > 0) && (
        <p className="px-2 py-1 ui-text-sm text-muted-foreground" data-slot="problems-truncated">
          {[
            hidden > 0 ? t("buildOutput.moreProblems", { count: hidden }) : null,
            diagnosticsDropped > 0
              ? t("buildOutput.diagnosticsTruncated", { count: diagnosticsDropped })
              : null,
          ]
            .filter(Boolean)
            .join(" ")}
        </p>
      )}
    </div>
  );
}
