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
    { resolveJavaLspLaunch, mavenLaunchContextForWorkspace },
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
