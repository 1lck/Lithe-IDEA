import { expect, mock, test } from "bun:test";
import { loadJavaNavigationMarkers } from "./java-navigation-marker-loader";

test("attaches the Java document before requesting gutter markers", async () => {
  const calls: string[] = [];
  const ensureDocumentReady = mock(async () => {
    calls.push("ensureDocumentReady");
    return {
      phase: "ready" as const,
      languageId: "java",
      workspacePath: "C:/work",
      feature: "supported" as const,
    };
  });
  const getJavaNavigationMarkers = mock(async () => {
    calls.push("getJavaNavigationMarkers");
    return [
      {
        line: 3,
        utf16Column: 7,
        implementationCount: 1,
        direction: "down" as const,
        relation: "interface" as const,
      },
    ];
  });

  const target = { filePath: "C:/work/src/Service.java", languageId: "java" };
  const markers = await loadJavaNavigationMarkers({
    client: { ensureDocumentReady, getJavaNavigationMarkers },
    target,
    workspaceScope: { workspaceId: "workspace-a", root: "C:/work" },
    content: "interface Service {}",
  });

  expect(calls).toEqual(["ensureDocumentReady", "getJavaNavigationMarkers"]);
  expect(ensureDocumentReady).toHaveBeenCalledWith(
    target,
    { workspaceId: "workspace-a", root: "C:/work" },
    "interface Service {}",
    "codeLens",
  );
  expect(markers).toHaveLength(1);
});
