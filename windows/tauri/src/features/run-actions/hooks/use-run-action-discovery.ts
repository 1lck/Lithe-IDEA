import { uiExtensionHost } from "@/extensions/ui/services/ui-extension-host";
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
  const enabledExtensions = useExtensionStore((state) =>
    [...state.availableExtensions.values()]
      .filter((ext) => ext.isInstalled && ext.isEnabled && ext.manifest.runActions)
      .map((ext) => ext.manifest.id)
      .sort()
      .join("\n"),
  );
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

    void Promise.all([
      discoverProjectRunActions(workspacePath),
      uiExtensionHost.discoverRunActions(workspacePath),
    ])
      .then((groups) => groups.flat())
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
  }, [enabled, revision, workspacePath, enabledExtensions]);

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
    projectActions: projectActions.filter(
      (action) => !action.extensionId || enabledExtensions.split("\n").includes(action.extensionId),
    ),
    lspActions,
    isDiscovering,
    discoveryError,
    refresh,
  };
}
