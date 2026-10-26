import { assertPluginActive, pluginPlanGuard } from "./declarative-plugin-lifecycle";
import { createElement } from "react";
import { saveWorkspaceBeforeLaunch } from "@/features/editor/services/save-workspace-before-launch";
import { ensureRunProcessListeners } from "@/features/run/hooks/use-run-process-events";
import { stopRunProcess } from "@/features/run/api/run-host-api";
import {
  bindRunSessionWorkspace,
  releaseRunSessionWorkspace,
  useRunStore,
} from "@/features/run/stores/run.store";
import { useUIState } from "@/features/window/stores/ui-state.store";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { createTranslator } from "@/i18n/locale";
import { showConfirmDialog } from "@/ui/dialog";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { isWorkspaceClosing } from "@/features/workspace/services/workspace-lifecycle";
import type { WorkspaceRuntime } from "@/features/workspace/types/workspace-runtime.types";
import {
  workspaceScopeMatchesRoot,
  type WorkspaceLaunchScope,
} from "@/features/workspace/types/workspace-launch-scope";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { probeDeclarativeExecutionOwner } from "@/features/editor/lsp/declarative-language-support";
import type { RunActionItem } from "@/features/run-actions/types/run-action.types";
import {
  getDeclarativePluginManifest,
  resolveDeclarativeRunPlan,
  resolveDeclarativeTestPlan,
  discoverDeclarativeTests,
  startDeclarativeExecution,
  setDeclarativeExecutionContext,
  type DeclarativeExecutionContext,
  type DeclarativeExecutionSelection,
  type DeclarativeRunPlan,
} from "./declarative-plugin-launch";
import { declarativePluginProcessOwner } from "./declarative-plugin-process-owner";

const incarnations = new WeakMap<WorkspaceRuntime, string>();
let contextRevision = 0;
const clientId = crypto.randomUUID();

export function declarativeExecutionErrorMessage(error: unknown): string {
  const message = error instanceof Error ? error.message : String(error);
  if (!message.startsWith("plugin.")) return message;
  return createTranslator(useSettingsStore.getState().settings.displayLanguage)(
    "plugins.execution.failed",
    { code: message },
  );
}

function capture(scope: WorkspaceLaunchScope, onStale: () => void = () => {}) {
  const runtime = workspaceRuntimeRegistry.getWorkspace(scope.workspaceId);
  let stale = false;
  const current = () =>
    Boolean(
      runtime &&
      !isWorkspaceClosing(scope.workspaceId) &&
      workspaceRuntimeRegistry.getWorkspace(scope.workspaceId) === runtime &&
      workspaceRuntimeRegistry.getActiveWorkspaceId() === scope.workspaceId &&
      workspaceScopeMatchesRoot(scope, runtime.descriptor.path),
    );
  const release = workspaceRuntimeRegistry.subscribe(() => {
    if (!current() && !stale) {
      stale = true;
      if (runtime) incarnations.delete(runtime);
      onStale();
    }
  });
  const assertCurrent = () => {
    if (stale || !current()) throw new Error("plugin.execution.staleContext");
  };
  try {
    assertCurrent();
  } catch (error) {
    release();
    throw error;
  }
  let generation = incarnations.get(runtime!);
  if (!generation) {
    generation = crypto.randomUUID();
    incarnations.set(runtime!, generation);
  }
  return {
    assertCurrent,
    release,
    context: { clientId, workspaceId: scope.workspaceId, workspacePath: scope.root, generation },
  };
}

export interface DeclarativeExecutionDependencies {
  owner: typeof probeDeclarativeExecutionOwner;
  manifest: typeof getDeclarativePluginManifest;
  discover: typeof discoverDeclarativeTests;
  runPlan: typeof resolveDeclarativeRunPlan;
  testPlan: typeof resolveDeclarativeTestPlan;
  save: typeof saveWorkspaceBeforeLaunch;
  synchronize: (workspaceId: string) => Promise<void>;
  confirm: (
    plan: DeclarativeRunPlan,
    context: DeclarativeExecutionContext,
    selection: DeclarativeExecutionSelection,
    signal: AbortSignal,
  ) => Promise<boolean>;
  listen: typeof ensureRunProcessListeners;
  start: typeof startDeclarativeExecution;
  stop: typeof stopRunProcess;
  context: typeof setDeclarativeExecutionContext;
}

const dependencies: DeclarativeExecutionDependencies = {
  owner: probeDeclarativeExecutionOwner,
  manifest: getDeclarativePluginManifest,
  discover: discoverDeclarativeTests,
  runPlan: resolveDeclarativeRunPlan,
  testPlan: resolveDeclarativeTestPlan,
  save: saveWorkspaceBeforeLaunch,
  synchronize: async (workspaceId) => {
    const { LspClient } = await import("@/features/editor/lsp/lsp-client");
    for (const buffer of useBufferStore.getStore(workspaceId).getState().buffers) {
      if (buffer.type === "editor")
        await LspClient.getInstance().synchronizeDocument(buffer.path, buffer.content);
    }
  },
  confirm: (plan, context, selection, signal) => {
    const t = createTranslator(useSettingsStore.getState().settings.displayLanguage);
    return showConfirmDialog(
      createElement(
        "span",
        { className: "block max-h-80 overflow-auto whitespace-pre-wrap break-all" },
        t("plugins.execution.review", {
          workspace: context.workspacePath,
          selection: JSON.stringify(selection),
          command: JSON.stringify({
            executable: plan.executable,
            arguments: plan.arguments,
            workingDirectory: plan.workingDirectory,
          }),
        }),
      ),
      { title: t("plugins.execution.reviewTitle"), confirmLabel: t("runActions.run"), signal },
    );
  },
  listen: ensureRunProcessListeners,
  start: startDeclarativeExecution,
  stop: stopRunProcess,
  context: setDeclarativeExecutionContext,
};

/** Discovery is read-only. Core returns workspace/file items; no source parser
 * or suite/case guesses are added here. Existing Worker run ownership wins. */
export async function declarativeRunActionsForFile(
  filePath: string,
  scope?: WorkspaceLaunchScope,
  ports: DeclarativeExecutionDependencies = dependencies,
): Promise<RunActionItem[]> {
  const revocations: Promise<void>[] = [];
  const captured = scope
    ? capture(scope, () => {
        const revoked = ports.context(clientId, ++contextRevision, null);
        revocations.push(revoked);
        void revoked.catch(() => {});
      })
    : undefined;
  const guard = pluginPlanGuard();
  try {
    if (captured) {
      await ports.context(clientId, ++contextRevision, captured.context);
      captured.assertCurrent();
    }
    const owner = await ports.owner(filePath);
    captured?.assertCurrent();
    if (!owner) return [];
    guard(owner.pluginId);
    const manifest = await ports.manifest(owner.pluginId);
    captured?.assertCurrent();
    guard(owner.pluginId);
    const providers = Array.isArray(manifest?.executionProviders)
      ? (manifest.executionProviders as Array<Record<string, unknown>>)
      : [];
    const provider = providers.find((item) => item.languageID === owner.languageId);
    if (!provider) return [];
    const t = createTranslator(useSettingsStore.getState().settings.displayLanguage);
    const base = {
      source: "declarative" as const,
      sourceLabel: owner.displayName,
      declarativeOwner: { pluginId: owner.pluginId, languageId: owner.languageId },
      declarativeValidate: () => guard(owner.pluginId),
      declarativeContext: captured?.context,
      description: owner.languageId,
    };
    const id = `declarative:${owner.pluginId}:${owner.languageId}`;
    const actions: RunActionItem[] =
      provider.run == null
        ? []
        : [
            {
              ...base,
              id: `${id}:run`,
              name: `${t("runActions.run")} ${owner.displayName}`,
              declarativeTest: false,
            },
          ];
    if (provider.test != null) {
      if (!captured) {
        // Legacy plan-only callers keep their API 1/2 workspace action.
        actions.push({
          ...base,
          id: `${id}:test`,
          name: `${t("runActions.test")} ${owner.displayName}`,
          declarativeTest: true,
        });
      } else {
        const tests = await ports.discover(owner.pluginId, owner.languageId, captured.context);
        captured.assertCurrent();
        guard(owner.pluginId);
        const relative = toWorkspaceRelative(filePath, scope!.root);
        for (const item of tests.items) {
          if (item.kind === "file" && item.relativeFilePath !== relative) continue;
          if (item.kind !== "workspace" && item.kind !== "file")
            throw new Error("plugin.execution.invalidPlan");
          actions.push({
            ...base,
            id: `${id}:test:${item.id}`,
            name: `${t("runActions.test")} ${item.label}`,
            declarativeTest: true,
            declarativeTestScope:
              item.kind === "workspace"
                ? { kind: "workspace" }
                : { kind: "file", relativeFilePath: item.relativeFilePath! },
          });
        }
      }
    }
    return actions;
  } finally {
    captured?.release();
    await Promise.all(revocations);
  }
}

function bufferSnapshot(workspaceId: string): string {
  return JSON.stringify(
    useBufferStore
      .getStore(workspaceId)
      .getState()
      .buffers.filter((buffer) => buffer.type === "editor")
      .map((buffer) => ({
        path: buffer.path,
        content: buffer.content,
        dirty: buffer.isDirty,
        lifecycle: buffer.documentLifecycle,
      })),
  );
}

/** Save -> synchronize -> exact Core plan -> explicit approval -> guarded
 * native start. The existing owner registers before the first async launch. */
export async function runDeclarativeAction(
  action: RunActionItem,
  workspaceId: string,
  root: string,
  filePath: string,
  ports: DeclarativeExecutionDependencies = dependencies,
): Promise<void> {
  const owner = action.declarativeOwner;
  if (!owner) throw new Error("plugin.execution.unavailable");
  assertPluginActive(owner.pluginId);
  action.declarativeValidate?.();
  const approval = new AbortController();
  const revocations: Promise<void>[] = [];
  const revoke = () => {
    if (approval.signal.aborted) return;
    approval.abort();
    const revoked = ports.context(clientId, ++contextRevision, null);
    revocations.push(revoked);
    void revoked.catch(() => {});
  };
  const scope = capture({ workspaceId, root }, revoke);
  let preparing = true;
  let releaseBuffers = () => {};
  const guard = pluginPlanGuard();
  const assertCurrent = () => {
    if (approval.signal.aborted) throw new Error("plugin.execution.staleContext");
    scope.assertCurrent();
    guard(owner.pluginId);
    action.declarativeValidate?.();
  };
  const id = `declarative:${owner.pluginId}:${crypto.randomUUID()}`;
  const store = useRunStore.getStore(workspaceId);
  let nativeProcessMayExist = false;
  const stop = async (exitCode = -1) => {
    await ports.stop(id, id);
    nativeProcessMayExist = false;
    store.getState().actions.finishProcess(id, exitCode);
    releaseRunSessionWorkspace(id);
  };
  try {
    if (
      action.declarativeContext &&
      Object.keys(scope.context).some(
        (key) =>
          action.declarativeContext![key as keyof DeclarativeExecutionContext] !==
          scope.context[key as keyof DeclarativeExecutionContext],
      )
    ) {
      throw new Error("plugin.execution.staleContext");
    }
    const relative = toWorkspaceRelative(filePath, root);
    const selection: DeclarativeExecutionSelection = action.declarativeTest
      ? { kind: "test", scope: action.declarativeTestScope ?? { kind: "workspace" } }
      : { kind: "run", relativeFilePath: relative, userArguments: [] };
    if (selection.kind === "test" && selection.scope.kind === "suite")
      throw new Error("plugin.execution.unavailable");
    await declarativePluginProcessOwner.start(
      id,
      workspaceId,
      owner.pluginId,
      async () => {
        assertCurrent();
        await ports.context(clientId, ++contextRevision, scope.context);
        assertCurrent();
        const liveOwner = await ports.owner(filePath);
        assertCurrent();
        if (liveOwner?.pluginId !== owner.pluginId || liveOwner.languageId !== owner.languageId)
          throw new Error("plugin.execution.staleContext");
        await ports.save(workspaceId);
        assertCurrent();
        const saved = bufferSnapshot(workspaceId);
        if (
          useBufferStore
            .getStore(workspaceId)
            .getState()
            .buffers.some(
              (buffer) =>
                buffer.type === "editor" &&
                !buffer.readOnly &&
                (buffer.isDirty || buffer.documentLifecycle?.status === "saving"),
            )
        ) {
          throw new Error("plugin.execution.staleContext");
        }
        releaseBuffers = useBufferStore.getStore(workspaceId).subscribe(() => {
          if (bufferSnapshot(workspaceId) !== saved) revoke();
        });
        await ports.synchronize(workspaceId);
        assertCurrent();
        const plan =
          selection.kind === "test"
            ? await ports.testPlan(
                owner.pluginId,
                owner.languageId,
                root,
                selection.scope,
                scope.context,
              )
            : await ports.runPlan(owner.pluginId, owner.languageId, relative, [], scope.context);
        assertCurrent();
        if (
          !plan.identity ||
          plan.pluginId !== owner.pluginId ||
          plan.languageId !== owner.languageId
        )
          throw new Error("plugin.execution.invalidPlan");
        if (!(await ports.confirm(plan, scope.context, selection, approval.signal))) return;
        assertCurrent();
        if (bufferSnapshot(workspaceId) !== saved) throw new Error("plugin.execution.staleContext");
        await ports.listen();
        assertCurrent();
        if (bufferSnapshot(workspaceId) !== saved) throw new Error("plugin.execution.staleContext");
        bindRunSessionWorkspace(id, workspaceId);
        store.setState((state) => ({
          sessions: [
            ...state.sessions,
            {
              id,
              configurationId: id,
              title: plan.label ?? action.name,
              output: "",
              isRunning: true,
              exitCode: null,
            },
          ],
          selectedSessionId: id,
        }));
        const ui = useUIState.getState();
        ui.setBottomPaneActiveTab("run");
        ui.setIsBottomPaneVisible(true);
        try {
          // A rejected IPC can still mean native published a process and failed
          // to stop it. Only a confirmed stop can release this ownership again.
          nativeProcessMayExist = true;
          await ports.start({
            ...owner,
            context: scope.context,
            selection,
            expectedIdentity: plan.identity,
            sessionId: id,
            executionId: id,
          });
          assertCurrent();
        } catch (error) {
          await stop(1);
          throw error;
        }
      },
      stop,
      () => {
        if (preparing) revoke();
      },
      () => nativeProcessMayExist,
    );
    // Cancelled review owns no process; do not retain it until window close.
    if (!store.getState().sessions.some((session) => session.id === id))
      declarativePluginProcessOwner.finished(id);
  } finally {
    preparing = false;
    releaseBuffers();
    scope.release();
    await Promise.all(revocations);
  }
}

function toWorkspaceRelative(filePath: string, root: string): string {
  const normalized = filePath.replace(/\\/g, "/");
  const base = root.replace(/\\/g, "/").replace(/\/$/, "");
  if (!normalized.toLowerCase().startsWith(`${base.toLowerCase()}/`))
    throw new Error("plugin.path.invalid");
  const relative = normalized.slice(base.length + 1);
  if (
    !relative ||
    relative.includes(":") ||
    relative.split("/").some((part) => !part || part === "." || part === "..")
  )
    throw new Error("plugin.path.invalid");
  return relative;
}
