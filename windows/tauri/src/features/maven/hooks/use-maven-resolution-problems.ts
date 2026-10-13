import { useEffect, useMemo, useRef } from "react";
import { toast } from "sonner";
import { useDiagnosticsStore } from "@/features/diagnostics/stores/diagnostics.store";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { useTranslation } from "@/i18n/locale-provider";
import { useMavenStore } from "../stores/maven.store";
import {
  mavenResolutionProblems,
  mavenResolutionProblemsSignature,
  type MavenResolutionProblem,
} from "../utils/maven-resolution-problems";

/** Maven problems JDT LS currently reports for the active workspace. */
export function useMavenResolutionProblems(): MavenResolutionProblem[] {
  const root = useMavenStore((state) => state.root);
  const diagnosticsByOwner = useDiagnosticsStore.use.diagnosticsByOwner();
  return useMemo(
    () => mavenResolutionProblems(root, diagnosticsByOwner),
    [root, diagnosticsByOwner],
  );
}

/** Opens the `pom.xml` location a problem points at. */
export function useOpenMavenResolutionProblem(): (problem: MavenResolutionProblem) => void {
  const handleFileSelect = useFileSystemStore.use.handleFileSelect?.();
  return (problem) => {
    void handleFileSelect?.(problem.pomPath, false, problem.line + 1, problem.column + 1, undefined, false);
  };
}

/**
 * Notifies once per distinct set of Maven problems in the active workspace.
 *
 * Mounted by the main layout so the notice appears even when the Maven tool
 * window is closed: a failed import is otherwise indistinguishable from a
 * successful one until every third-party import turns red (#970).
 */
export function useMavenResolutionNotifications(): void {
  const { t } = useTranslation();
  const root = useMavenStore((state) => state.root);
  const problems = useMavenResolutionProblems();
  const openProblem = useOpenMavenResolutionProblem();
  const signature = mavenResolutionProblemsSignature(problems);
  const notified = useRef(new Map<string, string>());
  const latest = useRef({ problems, openProblem, t });
  latest.current = { problems, openProblem, t };

  useEffect(() => {
    if (!root) return;
    const id = `maven-resolution:${root}`;
    if (!signature) {
      // Keep the last signature: the same failure reappearing after a rebuild
      // is still visible in the Maven tool window and needs no second notice.
      toast.dismiss(id);
      return;
    }
    if (notified.current.get(root) === signature) return;
    notified.current.set(root, signature);
    const { problems: current, openProblem: open, t: translate } = latest.current;
    const first = current[0]!;
    toast.warning(translate("maven.resolutionProblems", { count: current.length }), {
      id,
      description: first.message,
      duration: Infinity,
      action: { label: translate("maven.openPom"), onClick: () => open(first) },
    });
  }, [root, signature]);
}
