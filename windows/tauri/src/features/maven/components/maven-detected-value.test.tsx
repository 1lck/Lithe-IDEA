import { afterEach, expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { WorkspaceStoreScopeContext } from "@/features/workspace/stores/create-workspace-scoped-store";
import { LocaleProvider } from "@/i18n/locale-provider";
import type { MavenEffectiveConfiguration } from "../types/maven.types";
import { MavenDetectedValue } from "./maven-detected-value";

const workspaceId = "maven-detected-value-test";
const effective: MavenEffectiveConfiguration = {
  settingsPath: "D:/team/settings.xml",
  localRepositoryPath: "D:/team/repository",
  mavenExecutablePath: "D:/team/maven/bin/mvn.cmd",
  javaHomePath: "D:/team/jdk-21",
  detectedSettingsPath: "C:/fixture/.m2/settings.xml",
  detectedLocalRepositoryPath: "C:/fixture/.m2/repository",
  detectedMavenExecutablePath: "C:/fixture/maven/bin/mvn.cmd",
  detectedJavaHomePath: "C:/fixture/jdk-17",
};

function renderHint(props: Parameters<typeof MavenDetectedValue>[0]) {
  return renderToStaticMarkup(
    <WorkspaceStoreScopeContext.Provider value={workspaceId}>
      <LocaleProvider language="en-US">
        <MavenDetectedValue {...props} />
      </LocaleProvider>
    </WorkspaceStoreScopeContext.Provider>,
  );
}

afterEach(() => workspaceRuntimeRegistry.removeWorkspace(workspaceId));

test("an empty repository field shows the repository from the selected settings file", () => {
  const html = renderHint({ field: "localRepositoryPath", value: "", effective, status: "ready" });
  expect(html).toContain("D:/team/repository");
  expect(html).not.toContain("C:/fixture/.m2/repository");
});

test("inherited JDK and Maven hints reflect the effective selection", () => {
  for (const field of ["javaHomePath", "mavenExecutablePath", "settingsPath"] as const) {
    const html = renderHint({ field, value: "", effective, status: "ready" });
    expect(html).toContain(effective[field]!);
    expect(html).not.toContain("C:/fixture/");
  }
});

test("an explicit path does not display an inactive automatic fallback", () => {
  expect(renderHint({ field: "settingsPath", value: "D:/custom.xml", effective, status: "ready" }))
    .toBe("");
});

test("a previous result is hidden while the new configuration is loading or failed", () => {
  for (const status of ["loading", "failed"] as const) {
    const html = renderHint({ field: "localRepositoryPath", value: "", effective, status });
    expect(html).toContain('data-maven-detected="localRepositoryPath"');
    expect(html).not.toContain("D:/team/repository");
  }
});
