import { afterEach, beforeEach, expect, mock, spyOn, test } from "bun:test";
import * as javaConfiguration from "@/features/maven/services/java-maven-configuration";
import * as lspAdapter from "@/platform/lsp-core-adapter";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { setPluginActive } from "@/features/plugins/declarative-plugin-lifecycle";
import { useBuildSystemsStore } from "./build-systems-store";
import {
  prepareBuildLanguageImport,
  bindJavaBuildLanguageImport,
  javaBuildImportSource,
  updateBuildLanguageImport,
  type BuildLanguageImport,
  type BuildLanguageImportDependencies,
} from "./build-language-import";

const scope = { workspaceId: "import-fixture", root: "C:/fixture" };
const store = () => useBuildSystemsStore.getStore(scope.workspaceId);
const value: BuildLanguageImport = {
  workspaceRoot: scope.root,
  generation: 3,
  identity: "native-snapshot",
  mavenContext: {
    version: 1,
    reactorPath: "nested",
    profiles: ["dev"],
    settingsPath: "C:/fixture/settings.xml",
  },
  javaGradle: null,
};
function ready() {
  store().setState({ status: "ready", generation: 3, workspaceRoot: scope.root });
}
beforeEach(() => {
  workspaceRuntimeRegistry.resetForTests();
  workspaceRuntimeRegistry.activateWorkspace(
    { id: scope.workspaceId, name: "Import", path: scope.root },
    "ready",
  );
  ready();
});
afterEach(() => workspaceRuntimeRegistry.resetForTests());

function ports(read: BuildLanguageImportDependencies["read"] = async () => value) {
  return {
    refresh: mock(async () => []),
    read: mock(read),
  } satisfies BuildLanguageImportDependencies;
}
function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((done) => {
    resolve = done;
  });
  return { resolve, promise };
}

test("passes the exact workspace, source and generation; validation rechecks native identity", async () => {
  const bridge = ports();
  const prepared = await prepareBuildLanguageImport(
    scope,
    "C:/fixture/nested/src/App.java",
    bridge,
  );
  try {
    expect(prepared.value).toEqual(value);
    await prepared.validate();
    expect(bridge.read.mock.calls.map(([request]) => request)).toEqual([
      {
        workspaceRoot: scope.root,
        generation: 3,
        sourcePath: "nested/src/App.java",
        expectedIdentity: null,
      },
      {
        workspaceRoot: scope.root,
        generation: 3,
        sourcePath: "nested/src/App.java",
        expectedIdentity: value.identity,
      },
    ]);
    expect(bridge.refresh).not.toHaveBeenCalled();
  } finally {
    prepared.dispose();
  }
}, 2000);

test("initial discovery is passive and a missing or failed native model never becomes legacy fallback", async () => {
  store().setState({ status: "idle", generation: null });
  const bridge = ports();
  bridge.refresh.mockImplementation(async () => {
    ready();
    return [];
  });
  const prepared = await prepareBuildLanguageImport(scope, undefined, bridge);
  prepared.dispose();
  expect(bridge.refresh).toHaveBeenCalledTimes(1);
  for (const failure of [
    "plugin.build.invalidPlan",
    "plugin.build.invalidSelection",
    "plugin.build.modelReloadRequired",
  ]) {
    await expect(
      prepareBuildLanguageImport(
        scope,
        undefined,
        ports(async () => {
          throw new Error(failure);
        }),
      ),
    ).rejects.toThrow(failure);
  }
}, 2000);

test.each(["option", "model", "close", "switch-back"])(
  "discards a deferred import after %s",
  async (change) => {
    const answer = deferred<BuildLanguageImport>();
    const entered = deferred<void>();
    const bridge = ports(async () => {
      entered.resolve();
      return answer.promise;
    });
    const task = prepareBuildLanguageImport(scope, "C:/fixture/App.java", bridge);
    // Observe rejection without making Bun drain this still-controlled promise
    // before the test has released its native response gate.
    const outcome = task.catch((error: unknown) => error);
    try {
      await entered.promise;
      if (change === "option") store().setState({ requestSequence: 1 });
      if (change === "model") store().setState({ generation: 4 });
      if (change === "close") {
        workspaceRuntimeRegistry.activateWorkspace({ id: "welcome-import", name: "Welcome" });
        workspaceRuntimeRegistry.removeWorkspace(scope.workspaceId);
      }
      if (change === "switch-back") {
        workspaceRuntimeRegistry.activateWorkspace({
          id: "other-import",
          name: "Other",
          path: "C:/other",
        });
        workspaceRuntimeRegistry.activateWorkspace(
          { id: scope.workspaceId, name: "Import", path: scope.root },
          "ready",
        );
      }
      answer.resolve(value);
      const error = await outcome;
      expect(error).toBeInstanceOf(Error);
      expect((error as Error).message).toContain("plugin.build.staleContext");
    } finally {
      answer.resolve(value);
      await task.catch(() => undefined);
    }
  },
  2000,
);

test("same-version package replacement cannot reuse a previously prepared identity", async () => {
  let reads = 0;
  const bridge = ports(async () => ({
    ...value,
    identity: ++reads === 1 ? "old-package-bytes" : "replacement-bytes",
  }));
  const prepared = await prepareBuildLanguageImport(scope, undefined, bridge);
  try {
    await expect(prepared.validate()).rejects.toThrow("plugin.build.staleContext");
  } finally {
    prepared.dispose();
  }
}, 2000);

test("plugin revocation invalidates the prepared import before another native read", async () => {
  const id = "io.example.build-import";
  setPluginActive(id, true);
  store().setState({
    windows: {
      fixture: {
        pluginId: id,
        buildSystemId: "arbitrary",
        displayName: "Fixture",
        selectedRoot: ".",
        instances: [],
      },
    },
  });
  const bridge = ports();
  const prepared = await prepareBuildLanguageImport(scope, undefined, bridge);
  try {
    setPluginActive(id, false);
    setPluginActive(id, true);
    await expect(prepared.validate()).rejects.toThrow("superseded");
    expect(bridge.read).toHaveBeenCalledTimes(1);
  } finally {
    prepared.dispose();
    setPluginActive(id, false);
  }
}, 2000);

test("representative sources carry only scope identity, never an old configuration", () => {
  bindJavaBuildLanguageImport(scope, "C:/fixture/nested/App.java");
  expect(javaBuildImportSource(scope)).toBe("C:/fixture/nested/App.java");
  expect(javaBuildImportSource({ ...scope, root: "C:/replacement" })).toBeUndefined();
});

test("standalone Java retains its legacy import without inventing a build workspace", async () => {
  workspaceRuntimeRegistry.activateWorkspace({ id: "loose-file", name: "Loose file" }, "empty");
  const bridge = ports();
  const prepared = await prepareBuildLanguageImport(
    { workspaceId: "loose-file", root: "C:/loose" },
    "C:/loose/App.java",
    bridge,
  );
  try {
    expect(prepared.value.mavenContext).toBeNull();
    expect(prepared.value.javaGradle).toBeNull();
    await prepared.validate();
    expect(bridge.read).not.toHaveBeenCalled();
    expect(bridge.refresh).not.toHaveBeenCalled();
    workspaceRuntimeRegistry.activateWorkspace(
      { id: "project", name: "Project", path: "C:/project" },
      "ready",
    );
    await expect(prepared.validate()).rejects.toThrow("staleContext");
  } finally {
    prepared.dispose();
  }
}, 2000);

test("option edit wiring updates a Maven-bound Java session but leaves Gradle for the next start", async () => {
  const update = spyOn(javaConfiguration, "updateJavaMavenConfiguration").mockResolvedValue({
    kind: "noSession",
  });
  try {
    bindJavaBuildLanguageImport(scope, "C:/fixture/App.java", false);
    await updateBuildLanguageImport(scope);
    expect(update).not.toHaveBeenCalled();
    bindJavaBuildLanguageImport(scope, "C:/fixture/nested/App.java", true);
    await updateBuildLanguageImport(scope);
    expect(update).toHaveBeenCalledWith(scope.root, null, false, scope);
  } finally {
    update.mockRestore();
  }
}, 2000);

test("another editor cannot redirect a live JDT session's import to a sibling reactor", async () => {
  bindJavaBuildLanguageImport(scope, "C:/fixture/north/App.java", true);
  const session = spyOn(lspAdapter, "getLspWorkspaceSessionSnapshot").mockReturnValue({
    id: "owned-java-session",
    workspacePath: scope.root,
    languageId: "java",
    phase: "ready",
    operationId: "start",
    featureState: { phase: "unknown" },
  });
  const bridge = ports();
  let prepared: Awaited<ReturnType<typeof prepareBuildLanguageImport>> | undefined;
  try {
    prepared = await prepareBuildLanguageImport(scope, "C:/fixture/south/App.java", bridge);
    expect(bridge.read.mock.calls[0][0].sourcePath).toBe("north/App.java");
    bindJavaBuildLanguageImport(scope, "C:/fixture/south/App.java", true);
    expect(javaBuildImportSource(scope)).toBe("C:/fixture/north/App.java");
  } finally {
    prepared?.dispose();
    session.mockRestore();
  }
}, 2000);
