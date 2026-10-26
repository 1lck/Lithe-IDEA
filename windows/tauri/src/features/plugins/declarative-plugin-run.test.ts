import { afterEach, beforeEach, expect, mock, test } from "bun:test";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { setPluginActive } from "./declarative-plugin-lifecycle";
import { declarativePluginProcessOwner } from "./declarative-plugin-process-owner";
import {
  declarativeRunActionsForFile,
  runDeclarativeAction,
  type DeclarativeExecutionDependencies,
} from "./declarative-plugin-run";
import type { DeclarativeRunPlan } from "./declarative-plugin-launch";
import { runStoreForSession, useRunStore } from "@/features/run/stores/run.store";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import type { EditorContent } from "@/features/panes/types/pane-content.types";

const scope = { workspaceId: "execution-fixture", root: "C:/fixture" };
const pluginId = "io.example.execution";
const file = "C:/fixture/nested/ItemTest.php";
const owner = { pluginId, languageId: "php", displayName: "Fixture" };
const plan: DeclarativeRunPlan = {
  ...owner,
  executable: { command: "php" },
  arguments: ["vendor/bin/phpunit", "nested/ItemTest.php"],
  workingDirectory: ".",
  identity: "accepted-bytes-and-selection",
};

function bridge() {
  const events: string[] = [];
  const ports: DeclarativeExecutionDependencies = {
    owner: mock(async () => owner),
    manifest: mock(async () => ({
      executionProviders: [{ languageID: "php", run: {}, test: {} }],
    })),
    discover: mock(async () => ({
      identity: "discovery",
      items: [
        { id: "php:workspace", label: "All PHP Tests", kind: "workspace" as const },
        {
          id: "php:file:nested/ItemTest.php",
          label: "nested/ItemTest.php",
          kind: "file" as const,
          relativeFilePath: "nested/ItemTest.php",
        },
        {
          id: "php:file:other/Test.php",
          label: "other/Test.php",
          kind: "file" as const,
          relativeFilePath: "other/Test.php",
        },
      ],
    })),
    runPlan: mock(async () => {
      events.push("run-plan");
      return plan;
    }),
    testPlan: mock(async () => {
      events.push("test-plan");
      return plan;
    }),
    save: mock(async () => {
      events.push("save");
    }),
    synchronize: mock(async () => {
      events.push("synchronize");
    }),
    confirm: mock(async () => {
      events.push("confirm");
      return true;
    }),
    listen: mock(async () => {
      events.push("listen");
    }),
    start: mock(async () => {
      events.push("start");
    }),
    stop: mock(async () => {
      events.push("stop");
    }),
    context: mock(async () => {}),
  };
  return { ports, events };
}
beforeEach(() => {
  workspaceRuntimeRegistry.resetForTests();
  workspaceRuntimeRegistry.activateWorkspace(
    { id: scope.workspaceId, name: "Fixture", path: scope.root },
    "ready",
  );
  setPluginActive(pluginId, true);
});
afterEach(async () => {
  await declarativePluginProcessOwner.stop(scope.workspaceId);
  setPluginActive(pluginId, false);
  workspaceRuntimeRegistry.resetForTests();
});
function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((done) => {
    resolve = done;
  });
  return { promise, resolve };
}

test("discovery exposes Core's workspace and current-file items without sibling widening", async () => {
  const { ports } = bridge();
  const actions = await declarativeRunActionsForFile(file, scope, ports);
  expect(actions.map((action) => action.declarativeTestScope)).toEqual([
    undefined,
    { kind: "workspace" },
    { kind: "file", relativeFilePath: "nested/ItemTest.php" },
  ]);
  expect(ports.discover).toHaveBeenCalledTimes(1);
  expect(ports.save).not.toHaveBeenCalled();
  expect(ports.start).not.toHaveBeenCalled();
}, 2000);

test("save and synchronization precede exact test planning, approval and existing-owner start", async () => {
  const { ports, events } = bridge();
  const actions = await declarativeRunActionsForFile(file, scope, ports);
  await runDeclarativeAction(actions[2]!, scope.workspaceId, scope.root, file, ports);
  expect(events).toEqual(["save", "synchronize", "test-plan", "confirm", "listen", "start"]);
  expect(ports.testPlan).toHaveBeenCalledWith(
    pluginId,
    "php",
    scope.root,
    { kind: "file", relativeFilePath: "nested/ItemTest.php" },
    actions[2]!.declarativeContext,
  );
  const call = (ports.start as ReturnType<typeof mock>).mock.calls[0][0];
  expect(call.selection).toEqual({
    kind: "test",
    scope: { kind: "file", relativeFilePath: "nested/ItemTest.php" },
  });
  expect(call.expectedIdentity).toBe(plan.identity);
  expect(call.sessionId).toBe(call.executionId);
  expect(useRunStore.getStore(scope.workspaceId).getState().sessions[0]?.id).toBe(call.sessionId);
  expect(ports.runPlan).not.toHaveBeenCalled();
}, 2000);

test("a supplied case identifier stays exact and a suite is unavailable", async () => {
  const { ports } = bridge();
  const [action] = await declarativeRunActionsForFile(file, scope, ports);
  await runDeclarativeAction(
    {
      ...action!,
      declarativeTest: true,
      declarativeTestScope: {
        kind: "testCase",
        identifier: "Suite.test[one]",
        relativeFilePath: "nested/ItemTest.php",
      },
    },
    scope.workspaceId,
    scope.root,
    file,
    ports,
  );
  expect((ports.testPlan as ReturnType<typeof mock>).mock.calls[0][3]).toEqual({
    kind: "testCase",
    identifier: "Suite.test[one]",
    relativeFilePath: "nested/ItemTest.php",
  });
  await expect(
    runDeclarativeAction(
      {
        ...action!,
        declarativeTest: true,
        declarativeTestScope: { kind: "suite", identifier: "Suite" },
      },
      scope.workspaceId,
      scope.root,
      file,
      ports,
    ),
  ).rejects.toThrow("unavailable");
  expect(ports.testPlan).toHaveBeenCalledTimes(1);
}, 2000);

test.each(["save", "synchronize", "testPlan"] as const)(
  "%s failure never starts or falls back to running the file",
  async (step) => {
    const { ports } = bridge();
    const actions = await declarativeRunActionsForFile(file, scope, ports);
    (ports[step] as ReturnType<typeof mock>).mockRejectedValue(new Error("fixture rejected"));
    await expect(
      runDeclarativeAction(actions[2]!, scope.workspaceId, scope.root, file, ports),
    ).rejects.toThrow("fixture rejected");
    expect(ports.start).not.toHaveBeenCalled();
    expect(ports.runPlan).not.toHaveBeenCalled();
  },
  2000,
);

test("cancelled review starts no process and registers no output session", async () => {
  const { ports } = bridge();
  (ports.confirm as ReturnType<typeof mock>).mockResolvedValue(false);
  const actions = await declarativeRunActionsForFile(file, scope, ports);
  await runDeclarativeAction(actions[2]!, scope.workspaceId, scope.root, file, ports);
  expect(ports.start).not.toHaveBeenCalled();
  expect(useRunStore.getStore(scope.workspaceId).getState().sessions).toEqual([]);
}, 2000);

test("switch-away-and-back during approval revokes native context and cannot start a late result", async () => {
  const { ports } = bridge();
  const entered = deferred<void>();
  const approval = deferred<boolean>();
  (ports.confirm as ReturnType<typeof mock>).mockImplementation(async () => {
    entered.resolve();
    return approval.promise;
  });
  const actions = await declarativeRunActionsForFile(file, scope, ports);
  const task = runDeclarativeAction(actions[2]!, scope.workspaceId, scope.root, file, ports);
  const rejected = task.then(
    () => null,
    (error: unknown) => error,
  );
  try {
    await entered.promise;
    workspaceRuntimeRegistry.activateWorkspace(
      { id: "other", name: "Other", path: "C:/other" },
      "ready",
    );
    workspaceRuntimeRegistry.activateWorkspace(
      { id: scope.workspaceId, name: "Fixture", path: scope.root },
      "ready",
    );
    approval.resolve(true);
    expect(await rejected).toHaveProperty("message", "plugin.execution.staleContext");
    expect(ports.context).toHaveBeenCalledWith(expect.any(String), expect.any(Number), null);
    expect(ports.start).not.toHaveBeenCalled();
  } finally {
    approval.resolve(false);
    await task.catch(() => undefined);
  }
}, 2000);

test("owner stop cancels a pending approval before waiting for the launch to drain", async () => {
  const { ports } = bridge();
  const entered = deferred<void>();
  (ports.confirm as ReturnType<typeof mock>).mockImplementation(
    async (_plan, _scope, _selection, signal: AbortSignal) =>
      new Promise<boolean>((resolve) => {
        signal.addEventListener("abort", () => resolve(false), { once: true });
        entered.resolve();
      }),
  );
  const actions = await declarativeRunActionsForFile(file, scope, ports);
  const task = runDeclarativeAction(actions[2]!, scope.workspaceId, scope.root, file, ports);
  try {
    await entered.promise;
    await declarativePluginProcessOwner.stop(scope.workspaceId);
    await task;
  } finally {
    await declarativePluginProcessOwner.stop(scope.workspaceId);
    await task;
  }
  expect(ports.start).not.toHaveBeenCalled();
}, 2000);

test("plugin revocation and native package-receipt rejection do not execute stale plans", async () => {
  const { ports } = bridge();
  const actions = await declarativeRunActionsForFile(file, scope, ports);
  (ports.confirm as ReturnType<typeof mock>).mockImplementation(async () => {
    setPluginActive(pluginId, false);
    return true;
  });
  await expect(
    runDeclarativeAction(actions[2]!, scope.workspaceId, scope.root, file, ports),
  ).rejects.toThrow("inactive");
  expect(ports.start).not.toHaveBeenCalled();
  setPluginActive(pluginId, true);
  const refreshed = await declarativeRunActionsForFile(file, scope, ports);
  (ports.confirm as ReturnType<typeof mock>).mockResolvedValue(true);
  (ports.start as ReturnType<typeof mock>).mockRejectedValue(
    new Error("plugin.execution.packageChanged"),
  );
  await expect(
    runDeclarativeAction(refreshed[2]!, scope.workspaceId, scope.root, file, ports),
  ).rejects.toThrow("packageChanged");
  expect(
    useRunStore
      .getStore(scope.workspaceId)
      .getState()
      .sessions.every((session) => !session.isRunning),
  ).toBe(true);
}, 2000);

test("an edit during synchronization revokes the saved snapshot before planning or launch", async () => {
  const { ports } = bridge();
  const actions = await declarativeRunActionsForFile(file, scope, ports);
  (ports.synchronize as ReturnType<typeof mock>).mockImplementation(async () => {
    useBufferStore.getStore(scope.workspaceId).setState({
      buffers: [
        {
          type: "editor",
          path: file,
          content: "new unsaved content",
          isDirty: true,
        } as EditorContent,
      ],
    });
  });
  await expect(
    runDeclarativeAction(actions[2]!, scope.workspaceId, scope.root, file, ports),
  ).rejects.toThrow("staleContext");
  expect(ports.testPlan).not.toHaveBeenCalled();
  expect(ports.start).not.toHaveBeenCalled();
}, 2000);

test("an action discovered before disable and reenable cannot enter a newer package generation", async () => {
  const { ports } = bridge();
  const actions = await declarativeRunActionsForFile(file, scope, ports);
  setPluginActive(pluginId, false);
  setPluginActive(pluginId, true);
  await expect(
    runDeclarativeAction(actions[2]!, scope.workspaceId, scope.root, file, ports),
  ).rejects.toThrow("superseded");
  expect(ports.save).not.toHaveBeenCalled();
  expect(ports.start).not.toHaveBeenCalled();
}, 2000);

test("closing a workspace during planning discards its late answer and a path outside is never widened", async () => {
  const { ports } = bridge();
  const entered = deferred<void>();
  const answer = deferred<DeclarativeRunPlan>();
  const actions = await declarativeRunActionsForFile(file, scope, ports);
  (ports.testPlan as ReturnType<typeof mock>).mockImplementation(async () => {
    entered.resolve();
    return answer.promise;
  });
  const task = runDeclarativeAction(actions[2]!, scope.workspaceId, scope.root, file, ports);
  const rejected = task.then(
    () => null,
    (error: unknown) => error,
  );
  try {
    await entered.promise;
    workspaceRuntimeRegistry.activateWorkspace({ id: "welcome", name: "Welcome" }, "empty");
    workspaceRuntimeRegistry.removeWorkspace(scope.workspaceId);
    answer.resolve(plan);
    expect(await rejected).toHaveProperty("message", "plugin.execution.staleContext");
    expect(ports.confirm).not.toHaveBeenCalled();
    expect(ports.start).not.toHaveBeenCalled();
  } finally {
    answer.resolve(plan);
    await task.catch(() => undefined);
  }
  workspaceRuntimeRegistry.activateWorkspace(
    { id: scope.workspaceId, name: "Fixture", path: scope.root },
    "ready",
  );
  await expect(
    runDeclarativeAction(
      { ...actions[0]!, declarativeContext: undefined },
      scope.workspaceId,
      scope.root,
      "C:/other/App.php",
      ports,
    ),
  ).rejects.toThrow("plugin.path.invalid");
  expect(ports.runPlan).not.toHaveBeenCalled();
}, 2000);

test("a late native start keeps its session and owner when cancellation cleanup fails", async () => {
  const { ports } = bridge();
  const entered = deferred<void>();
  const nativeStart = deferred<void>();
  (ports.start as ReturnType<typeof mock>).mockImplementation(async () => {
    entered.resolve();
    await nativeStart.promise;
  });
  (ports.stop as ReturnType<typeof mock>).mockRejectedValueOnce(new Error("stop unconfirmed"));
  const actions = await declarativeRunActionsForFile(file, scope, ports);
  const task = runDeclarativeAction(actions[2]!, scope.workspaceId, scope.root, file, ports);
  const rejected = task.then(
    () => null,
    (error: unknown) => error,
  );
  try {
    await entered.promise;
    workspaceRuntimeRegistry.activateWorkspace(
      { id: "other", name: "Other", path: "C:/other" },
      "ready",
    );
    nativeStart.resolve();
    expect(await rejected).toHaveProperty("message", "stop unconfirmed");
    const store = useRunStore.getStore(scope.workspaceId);
    const session = store.getState().sessions[0]!;
    expect(session.isRunning).toBe(true);
    expect(runStoreForSession(session.id)).toBe(store);
    expect(ports.stop).toHaveBeenCalledTimes(1);

    await declarativePluginProcessOwner.stop(undefined, pluginId);
    expect(ports.stop).toHaveBeenCalledTimes(2);
    expect(store.getState().sessions[0]!.isRunning).toBe(false);
    expect(runStoreForSession(session.id)).toBe(useRunStore);
    await declarativePluginProcessOwner.stop(undefined, pluginId);
    expect(ports.stop).toHaveBeenCalledTimes(2);
  } finally {
    nativeStart.resolve();
    await task.catch(() => undefined);
    await declarativePluginProcessOwner.stop(undefined, pluginId);
  }
}, 2000);

test("a rejected native start is released only after stop confirms there is no process", async () => {
  const { ports } = bridge();
  (ports.start as ReturnType<typeof mock>).mockRejectedValue(
    new Error("plugin.execution.packageChanged"),
  );
  const [action] = await declarativeRunActionsForFile(file, scope, ports);
  await expect(
    runDeclarativeAction(action!, scope.workspaceId, scope.root, file, ports),
  ).rejects.toThrow("packageChanged");
  const session = useRunStore.getStore(scope.workspaceId).getState().sessions[0]!;
  expect(session.isRunning).toBe(false);
  expect(session.exitCode).toBe(1);
  expect(runStoreForSession(session.id)).toBe(useRunStore);
  expect(ports.stop).toHaveBeenCalledTimes(1);
  await declarativePluginProcessOwner.stop(undefined, pluginId);
  expect(ports.stop).toHaveBeenCalledTimes(1);
}, 2000);
