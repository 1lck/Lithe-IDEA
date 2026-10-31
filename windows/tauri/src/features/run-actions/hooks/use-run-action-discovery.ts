import { uiExtensionHost } from "@/extensions/ui/services/ui-extension-host";
import {
  declarativeRunActionsForWorkspace,
  declarativeExecutionErrorMessage,
} from "@/features/plugins/declarative-plugin-run";
import { subscribePluginActivity } from "@/features/plugins/declarative-plugin-lifecycle";
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
import { mergeRunActions } from "../utils/merge-run-actions";
import { getRelativePath } from "@/utils/path-helpers";

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
  const [revision, setRevision] = useState(0);
  const [projectResult, setProjectResult] = useState<{
    key: string;
    actions: RunActionItem[];
  } | null>(null);
  const projectKey = JSON.stringify([
    workspaceId,
    workspacePath,
    enabledExtensions,
    revision,
    enabled,
  ]);
  const projectActions = projectResult?.key === projectKey ? projectResult.actions : [];
  const [isDiscovering, setIsDiscovering] = useState(false);
  const [discoveryError, setDiscoveryError] = useState<string | null>(null);
  const mavenKey = JSON.stringify([workspaceId, workspacePath, activeFilePath, enabled]);
  const [mavenAvailability, setMavenAvailability] = useState<{
    key: string;
    available: boolean;
  } | null>(null);
  const mavenTestsAvailable = mavenAvailability?.key === mavenKey && mavenAvailability.available;
  useEffect(() => subscribePluginActivity(() => setRevision((current) => current + 1)), []);
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
      setProjectResult(null);
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
        if (!cancelled) setProjectResult({ key: projectKey, actions });
      })
      .catch((error) => {
        if (cancelled) return;
        setProjectResult(null);
        setDiscoveryError(error instanceof Error ? error.message : "Could not scan project");
      })
      .finally(() => {
        if (!cancelled) setIsDiscovering(false);
      });

    return () => {
      cancelled = true;
    };
  }, [projectKey, enabled, revision, workspaceId, workspacePath, enabledExtensions]);

  useEffect(() => {
    if (!enabled || !workspacePath || !activeFilePath || !/\.java$/i.test(activeFilePath)) {
      setMavenAvailability(null);
      return;
    }

    let cancelled = false;
    setMavenAvailability(null);
    void canRunMavenTest(workspacePath, activeFilePath).then((available) => {
      if (!cancelled) setMavenAvailability({ key: mavenKey, available });
    });

    return () => {
      cancelled = true;
    };
  }, [mavenKey, activeFilePath, enabled, workspaceId, workspacePath]);

  const declarativeKey = JSON.stringify([projectKey, activeFilePath]);
  const [declarativeLoading, setDeclarativeLoading] = useState(false);
  const [declarativeResult, setDeclarativeResult] = useState<{
    key: string;
    actions: RunActionItem[];
  } | null>(null);
  const declarativeActions =
    declarativeResult?.key === declarativeKey ? declarativeResult.actions : [];
  useEffect(() => {
    if (!enabled || !workspacePath) {
      setDeclarativeResult(null);
      setDeclarativeLoading(false);
      return;
    }
    let cancelled = false;
    setDeclarativeResult(null);
    setDeclarativeLoading(true);
    void declarativeRunActionsForWorkspace({ workspaceId, root: workspacePath }, activeFilePath)
      .then((actions) => {
        if (!cancelled) setDeclarativeResult({ key: declarativeKey, actions });
      })
      .catch((error: unknown) => {
        if (!cancelled) {
          setDeclarativeResult(null);
          setDiscoveryError(declarativeExecutionErrorMessage(error));
        }
      })
      .finally(() => {
        if (!cancelled) setDeclarativeLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, [
    declarativeKey,
    activeFilePath,
    enabled,
    enabledExtensions,
    revision,
    workspaceId,
    workspacePath,
  ]);

  const lspActions = useMemo(
    () =>
      activeFilePath
        ? [
            ...(mavenTestsAvailable
              ? javaTestActionsForFile(activeFilePath, javaTestMethods).map((action) => ({
                  ...action,
                  testTarget: {
                    languageId: "java",
                    scope: action.mavenTest?.method
                      ? {
                          kind: "testCase" as const,
                          identifier: action.mavenTest.method,
                          relativeFilePath: getRelativePath(activeFilePath, workspacePath ?? ""),
                        }
                      : {
                          kind: "file" as const,
                          relativeFilePath: getRelativePath(activeFilePath, workspacePath ?? ""),
                        },
                  },
                }))
              : []),
            ...codeLensesToRunActions(codeLenses, activeFilePath),
          ]
        : [],
    [activeFilePath, codeLenses, javaTestMethods, mavenTestsAvailable, workspacePath],
  );
  const refresh = useCallback(() => setRevision((current) => current + 1), []);

  return {
    ...mergeRunActions(
      lspActions,
      projectActions.filter(
        (action) =>
          !action.extensionId || enabledExtensions.split("\n").includes(action.extensionId),
      ),
      declarativeActions,
    ),
    isDiscovering: isDiscovering || declarativeLoading,
    discoveryError,
    refresh,
  };
}
