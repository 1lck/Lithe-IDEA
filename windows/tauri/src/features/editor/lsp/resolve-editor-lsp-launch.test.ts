import { expect, mock, test } from "bun:test";

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

mock.module("./java-lsp-host-api", () => ({ resolveJavaLspLaunch }));
mock.module("@/features/maven/stores/maven.store", () => ({
  mavenLaunchContextForWorkspace,
}));

const { resolveEditorLspLaunch } = await import("./resolve-editor-lsp-launch");

test("forwards the current Maven context to the Java language server", async () => {
  const launch = await resolveEditorLspLaunch("D:/work/src/App.java", "D:/work");

  expect(mavenLaunchContextForWorkspace).toHaveBeenCalledWith("D:/work", ["src/App.java"]);
  expect(launch?.mavenContext).toEqual(
    expect.objectContaining({
      profiles: ["dev"],
      settingsPath: "C:/Users/example/.m2/settings.xml",
      skipTests: true,
    }),
  );
});
