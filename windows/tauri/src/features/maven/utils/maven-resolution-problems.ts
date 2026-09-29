import type { Diagnostic } from "@/features/diagnostics/types/diagnostics.types";

/** One error JDT LS reported on a Maven build file of the workspace. */
export interface MavenResolutionProblem {
  /** The `pom.xml` the problem belongs to, as the diagnostics store keys it. */
  pomPath: string;
  /** Directory of that `pom.xml` relative to the workspace root; `.` for the root. */
  modulePath: string;
  /** Zero-based position, as stored by the diagnostics model. */
  line: number;
  column: number;
  message: string;
}

const LSP_DIAGNOSTICS_OWNER = "lsp";

function comparablePath(path: string): string {
  const normalized = path.replace(/\\/g, "/").replace(/\/+$/, "");
  return /^(?:[A-Za-z]:\/|\/\/)/.test(normalized) ? normalized.toLowerCase() : normalized;
}

/**
 * Maven problems for the workspace at `root`, read from the language server's
 * `pom.xml` diagnostics.
 *
 * JDT LS imports Maven projects through m2e and reports every failure to read a
 * POM or resolve an artifact as an error marker on that `pom.xml`. Those
 * markers are the resolution result; without surfacing them a failed import
 * looks successful while every third-party import stays unresolved (#970).
 * Warnings such as an out-of-date project configuration are left to the
 * Problems view.
 */
export function mavenResolutionProblems(
  root: string | null,
  diagnosticsByOwner: ReadonlyMap<string, ReadonlyMap<string, readonly Diagnostic[]>>,
): MavenResolutionProblem[] {
  if (!root) return [];
  const rootKey = comparablePath(root);
  const problems: MavenResolutionProblem[] = [];
  for (const [filePath, owners] of diagnosticsByOwner) {
    const fileKey = comparablePath(filePath);
    if (!fileKey.endsWith("/pom.xml") || !fileKey.startsWith(`${rootKey}/`)) continue;
    const directory = fileKey.slice(rootKey.length + 1, -"/pom.xml".length);
    for (const diagnostic of owners.get(LSP_DIAGNOSTICS_OWNER) ?? []) {
      if (diagnostic.severity !== "error") continue;
      problems.push({
        pomPath: filePath,
        modulePath: directory || ".",
        line: diagnostic.line,
        column: diagnostic.column,
        message: diagnostic.message,
      });
    }
  }
  return problems.sort(
    (left, right) =>
      left.modulePath.localeCompare(right.modulePath) ||
      left.line - right.line ||
      left.column - right.column ||
      left.message.localeCompare(right.message),
  );
}

/** Stable identity of a problem set, used to notify once per distinct set. */
export function mavenResolutionProblemsSignature(problems: readonly MavenResolutionProblem[]): string {
  return problems
    .map((problem) => `${problem.modulePath}\0${problem.line}\0${problem.column}\0${problem.message}`)
    .join("\n");
}
