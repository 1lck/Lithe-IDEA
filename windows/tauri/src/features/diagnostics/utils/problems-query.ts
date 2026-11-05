import { invoke } from "@/platform/tauri-core";
import type { Diagnostic } from "../types/diagnostics.types";

export type ProblemsGroupBy = "severity" | "file" | "none";
export type ProblemsSortBy = "severity" | "file" | "position";

type Severity = Diagnostic["severity"];

const LSP_SEVERITY: Record<Severity, number> = { error: 1, warning: 2, info: 3 };

export interface ProblemsQueryOptions {
  groupBy: ProblemsGroupBy;
  sortBy: ProblemsSortBy;
  severities: Record<Severity, boolean>;
  /** Restricts the query to this file (case-insensitive on Windows). */
  currentFilePath: string | null;
  source: string | null;
  query: string;
  /** Workspace-relative label for each file; it decides file order. */
  displayPath: (filePath: string) => string;
}

export interface ProblemsGroup {
  id: string;
  kind: "file" | "severity" | "all";
  items: Diagnostic[];
  severity?: Severity;
}

export interface ProblemsFile {
  filePath: string;
  displayPath: string;
  total: number;
  severity: Severity;
}

export interface ProblemsQueryView {
  /** Visible diagnostics in display order. */
  visible: Diagnostic[];
  groups: ProblemsGroup[];
  files: ProblemsFile[];
  visibleBySeverity: Record<Severity, number>;
  totalBySeverity: Record<Severity, number>;
}

interface CoreCounts {
  error: number;
  warning: number;
  information: number;
  hint: number;
  unknown: number;
}

interface CoreResponse {
  groups: Array<{ key: string; kind: ProblemsGroup["kind"]; severity?: number; indices: number[] }>;
  files: Array<{ fileKey: string; displayPath: string; count: number; highestSeverity: number }>;
  visibleCounts: CoreCounts;
  totalCounts: CoreCounts;
}

export const EMPTY_PROBLEMS_VIEW: ProblemsQueryView = {
  visible: [],
  groups: [],
  files: [],
  visibleBySeverity: { error: 0, warning: 0, info: 0 },
  totalBySeverity: { error: 0, warning: 0, info: 0 },
};

/** Windows file identity: paths compare case-insensitively. */
const fileKey = (filePath: string) => filePath.toLowerCase();

const displaySeverity = (severity: number | undefined): Severity =>
  severity === 1 ? "error" : severity === 2 ? "warning" : "info";

const displayCounts = (counts: CoreCounts): Record<Severity, number> => ({
  error: counts.error,
  warning: counts.warning,
  // The pane shows information, hints, and unknown severities together.
  info: counts.information + counts.hint + counts.unknown,
});

/**
 * Filters, orders, and groups the Problems list with the shared Core rules
 * (`lsp.problems.query`); only presentation stays in the pane.
 */
export async function queryProblems(
  diagnostics: Diagnostic[],
  options: ProblemsQueryOptions,
): Promise<ProblemsQueryView> {
  if (diagnostics.length === 0) return EMPTY_PROBLEMS_VIEW;
  const severities = (Object.keys(LSP_SEVERITY) as Severity[])
    .filter((severity) => options.severities[severity])
    .map((severity) => LSP_SEVERITY[severity]);
  const query = options.query.trim();
  const response = await invoke<CoreResponse>("lsp.problems.query", {
    diagnostics: diagnostics.map((diagnostic) => ({
      fileKey: fileKey(diagnostic.filePath),
      displayPath: options.displayPath(diagnostic.filePath),
      line: diagnostic.line,
      column: diagnostic.column,
      severity: LSP_SEVERITY[diagnostic.severity],
      message: diagnostic.message,
      source: diagnostic.source ?? null,
      code: diagnostic.code ?? null,
    })),
    groupBy: options.groupBy,
    sortBy: options.sortBy,
    filter: {
      severities,
      fileKey: options.currentFilePath ? fileKey(options.currentFilePath) : null,
      source: options.source,
      query: query.length > 0 ? query : null,
    },
  });
  const filePaths = new Map<string, string>();
  for (const diagnostic of diagnostics) {
    const key = fileKey(diagnostic.filePath);
    if (!filePaths.has(key)) filePaths.set(key, diagnostic.filePath);
  }
  const groups = response.groups.map((group): ProblemsGroup => {
    const items = group.indices.map((index) => diagnostics[index]).filter(Boolean);
    if (group.kind === "file") {
      return { id: `file-${items[0]?.filePath ?? group.key}`, kind: "file", items };
    }
    if (group.kind === "severity") {
      const severity = displaySeverity(group.severity);
      return { id: `severity-${group.severity}`, kind: "severity", items, severity };
    }
    return { id: "all", kind: "all", items };
  });
  return {
    visible: groups.flatMap((group) => group.items),
    groups,
    files: response.files.map((file) => ({
      filePath: filePaths.get(file.fileKey) ?? file.fileKey,
      displayPath: file.displayPath,
      total: file.count,
      severity: displaySeverity(file.highestSeverity),
    })),
    visibleBySeverity: displayCounts(response.visibleCounts),
    totalBySeverity: displayCounts(response.totalCounts),
  };
}
