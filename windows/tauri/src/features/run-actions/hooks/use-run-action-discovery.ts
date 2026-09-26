import { useExtensionStore } from "@/extensions/registry/extension-store";
import { useCallback, useEffect, useMemo, useState } from "react";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { getBufferByPath } from "@/features/editor/utils/buffer-index";
import { canRunMavenTest } from "@/features/maven/services/maven-test-actions";
import { useJavaTestMethods } from "@/features/maven/hooks/use-java-test-methods";
import { useCodeLens } from "@/features/editor/lsp/use-code-lens";
import type { RunActionItem } from "../types/run-action.types";
import {
  codeLensesToRunActions,
  discoverProjectRunActions,
  javaTestActionsForFile,
} from "../utils/run-action-discovery";

export function useRunActionDiscovery(
  workspaceId: string,
  workspacePath: string | undefined,
  activeFilePath: string | undefined,
  includeCodeLenses: boolean,
  enabled = true,
) {
  const phpEnabled = useExtensionStore((state) => {
    const php = state.availableExtensions.get("lithe.php");
    return php?.isInstalled === true && php.isEnabled === true;
  });
  const [projectActions, setProjectActions] = useState<RunActionItem[]>([]);
  const [isDiscovering, setIsDiscovering] = useState(false);
  const [discoveryError, setDiscoveryError] = useState<string | null>(null);
  const [mavenTestsAvailable, setMavenTestsAvailable] = useState(false);
  const [revision, setRevision] = useState(0);
  const codeLenses = useCodeLens(activeFilePath, enabled && includeCodeLenses);
  const activeFileContent = useBufferStore((state) => {
    const buffer = getBufferByPath(state.buffers, activeFilePath);
    return buffer?.type === "editor" ? (buffer.content ?? "") : "";
  });
  const javaTestScope = useMemo(
    () => (workspacePath ? { workspaceId, root: workspacePath } : null),
    [workspaceId, workspacePath],
  );
  const javaTestMethods = useJavaTestMethods(
    javaTestScope,
    activeFilePath ?? "",
    activeFileContent,
    enabled && mavenTestsAvailable,
  );

  useEffect(() => {
    if (!enabled || !workspacePath) {
      setProjectActions([]);
      setDiscoveryError(null);
      return;
    }

    let cancelled = false;
    setIsDiscovering(true);
    setDiscoveryError(null);

    void discoverProjectRunActions(workspacePath, undefined, phpEnabled)
      .then((actions) => {
        if (!cancelled) setProjectActions(actions);
      })
      .catch((error) => {
        if (cancelled) return;
        setProjectActions([]);
        setDiscoveryError(error instanceof Error ? error.message : "Could not scan project");
      })
      .finally(() => {
        if (!cancelled) setIsDiscovering(false);
      });

    return () => {
      cancelled = true;
    };
  }, [enabled, revision, workspacePath, phpEnabled]);

  useEffect(() => {
    if (!enabled || !workspacePath || !activeFilePath || !/\.java$/i.test(activeFilePath)) {
      setMavenTestsAvailable(false);
      return;
    }

    let cancelled = false;
    setMavenTestsAvailable(false);
    void canRunMavenTest(workspacePath, activeFilePath).then((available) => {
      if (!cancelled) setMavenTestsAvailable(available);
    });

    return () => {
      cancelled = true;
    };
  }, [activeFilePath, enabled, workspacePath]);

  const lspActions = useMemo(
    () =>
      activeFilePath
        ? [
            ...(mavenTestsAvailable ? javaTestActionsForFile(activeFilePath, javaTestMethods) : []),
            ...codeLensesToRunActions(codeLenses, activeFilePath),
          ]
        : [],
    [activeFilePath, codeLenses, javaTestMethods, mavenTestsAvailable],
  );
  const refresh = useCallback(() => setRevision((current) => current + 1), []);

  return {
    projectActions: phpEnabled
      ? projectActions
      : projectActions.filter((action) => action.source !== "php"),
    lspActions,
    isDiscovering,
    discoveryError,
    refresh,
  };
}
