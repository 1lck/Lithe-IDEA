import { afterEach, expect, mock, test } from "bun:test";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { resolveEditorLspLaunch } from "./resolve-editor-lsp-launch";

afterEach(() => workspaceRuntimeRegistry.resetForTests());

const resolveJavaLspLaunch = mock(async () => ({
  providerId: "java",
  languageId: "java",
  executablePath: "C:/Lithe/jdtls/bin/jdtls.bat",
  arguments: [],
  runtimeExecutablePath: "C:/Lithe/jdk/bin/java.exe",
  cacheDirectory: "C:/Users/example/AppData/Local/Lithe/jdtls",
  environment: { JAVA_HOME: "C:/Lithe/jdk" },
  workspaceFingerprint: "workspace-fingerprint",
}));
const mavenLaunchContextForWorkspace = mock(async () => ({
  version: 1 as const,
  reactorPath: ".",
  profiles: ["dev"],
  settingsPath: "C:/Users/example/.m2/settings.xml",
  skipTests: true,
  mavenExecutablePath: "D:/Tools/apache-maven",
  javaHomePath: "C:/Java/jdk-21",
}));

test("resolves workspace A Maven context while workspace B is active", async () => {
  workspaceRuntimeRegistry.activateWorkspace({ id: "workspace-b", name: "B" }, "ready");
  const launch = await resolveEditorLspLaunch(
    "D:/work-a/src/App.java",
    {
      workspaceId: "workspace-a",
      root: "D:/work-a",
    },
    {
      resolveJavaLspLaunch,
      mavenLaunchContextForWorkspace,
      ensureWorkspaceGitBootstrap: async () => "skipped",
      resolveDeclarativePluginLaunch: async () => null,
    },
  );

  expect(workspaceRuntimeRegistry.getActiveWorkspaceId()).toBe("workspace-b");
  expect(mavenLaunchContextForWorkspace).toHaveBeenCalledWith(
    "D:/work-a",
    ["src/App.java"],
    "workspace-a",
  );
  expect(launch?.mavenContext).toEqual(
    expect.objectContaining({
      profiles: ["dev"],
      settingsPath: "C:/Users/example/.m2/settings.xml",
      skipTests: true,
    }),
  );
});

test("forwards the declared Gradle import context to the launch", async () => {
  const launch = await resolveEditorLspLaunch(
    "D:/work/src/App.java",
    { workspaceId: "workspace-a", root: "D:/work" },
    {
      resolveJavaLspLaunch: mock(async () => ({
        providerId: "java",
        languageId: "java",
        executablePath: "C:/Lithe/jdtls/bin/jdtls.bat",
        arguments: [],
        cacheDirectory: "C:/Users/example/AppData/Local/Lithe/jdtls",
        environment: {},
        javaGradle: { wrapperPresent: true },
      })),
      mavenLaunchContextForWorkspace,
      ensureWorkspaceGitBootstrap: async () => "skipped",
      resolveDeclarativePluginLaunch: async () => null,
    },
  );

  expect(launch?.javaGradle).toEqual({ wrapperPresent: true });
});

test("omits the Gradle import context for a workspace without one", async () => {
  const launch = await resolveEditorLspLaunch(
    "D:/work/src/App.java",
    { workspaceId: "workspace-a", root: "D:/work" },
    {
      resolveJavaLspLaunch,
      mavenLaunchContextForWorkspace,
      ensureWorkspaceGitBootstrap: async () => "skipped",
      resolveDeclarativePluginLaunch: async () => null,
    },
  );

  expect(launch?.javaGradle).toBeNull();
});

test("falls back to a declarative plugin launch when the registry has no server", async () => {
  const resolveDeclarativePluginLaunch = mock(async () => ({
    pluginId: "dev.lithe.plugin.php-support",
    languageId: "php",
    serverPath: "C:/Users/example/AppData/Local/Lithe/plugins/dev.lithe.plugin.php-support/1.0.0/language-server/bin/intelephense.js",
    serverArgs: ["--stdio"],
    initializationOptions: { memory: 4096 },
    workspaceConfiguration: { php: { format: true } },
    environment: { LITHE_NODE_PATH: "C:/Lithe/tools/node/node.exe" },
  }));
  const launch = await resolveEditorLspLaunch(
    "D:/work/src/Index.php",
    { workspaceId: "workspace-a", root: "D:/work" },
    {
      resolveJavaLspLaunch,
      mavenLaunchContextForWorkspace,
      ensureWorkspaceGitBootstrap: async () => "skipped",
      resolveDeclarativePluginLaunch,
    },
  );

  expect(resolveDeclarativePluginLaunch).toHaveBeenCalledWith(
    "D:/work/src/Index.php",
    "D:/work",
  );
  expect(launch).toEqual({
    providerId: "dev.lithe.plugin.php-support",
    languageId: "php",
    serverPath: "C:/Users/example/AppData/Local/Lithe/plugins/dev.lithe.plugin.php-support/1.0.0/language-server/bin/intelephense.js",
    serverArgs: ["--stdio"],
    initializationOptions: { memory: 4096 },
    workspaceConfiguration: { php: { format: true } },
    environment: { LITHE_NODE_PATH: "C:/Lithe/tools/node/node.exe" },
  });
});

test("returns null when neither the registry nor a declarative plugin owns the file", async () => {
  const launch = await resolveEditorLspLaunch(
    "D:/work/src/notes.txt",
    { workspaceId: "workspace-a", root: "D:/work" },
    {
      resolveJavaLspLaunch,
      mavenLaunchContextForWorkspace,
      ensureWorkspaceGitBootstrap: async () => "skipped",
      resolveDeclarativePluginLaunch: async () => null,
    },
  );

  expect(launch).toBeNull();
});
