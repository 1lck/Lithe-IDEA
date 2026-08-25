import { describe, expect, mock, test } from "bun:test";
import type { LspLocation } from "./lsp-client";
import { openLspNavigationLocation } from "./navigation-target";
import type { OpenContentSpec, PaneContent } from "@/features/panes/types/pane-content.types";

const range = {
  start: { line: 1, character: 2 },
  end: { line: 1, character: 3 },
};

function createOptions(location: LspLocation, buffers: PaneContent[] = []) {
  const openContent = mock((_spec: OpenContentSpec) => "opened-buffer");
  const setActiveBuffer = mock((_bufferId: string) => undefined);
  const updateBuffer = mock((_buffer: PaneContent) => undefined);
  const getVirtualDocument = mock(
    async (): Promise<string | null> => "public final class String {}",
  );
  const readFileContent = mock(async () => "class Main {}");

  return {
    options: {
      location,
      sourceFilePath: "C:/work/src/Main.java",
      buffers,
      actions: { openContent, setActiveBuffer, updateBuffer },
      getVirtualDocument,
      readFileContent,
    },
    openContent,
    setActiveBuffer,
    updateBuffer,
    getVirtualDocument,
    readFileContent,
  };
}

describe("LSP navigation targets", () => {
  test("opens physical file locations with their Core-projected path", async () => {
    const context = createOptions({
      uri: "file:///C:/work/src/Service.java",
      filePath: "C:/work/src/Service.java",
      range,
    });

    expect(await openLspNavigationLocation(context.options)).toBe("opened-buffer");
    expect(context.readFileContent).toHaveBeenCalledWith("C:/work/src/Service.java");
    expect(context.openContent).toHaveBeenCalledWith({
      type: "editor",
      path: "C:/work/src/Service.java",
      name: "Service.java",
      content: "class Main {}",
    });
    expect(context.getVirtualDocument).not.toHaveBeenCalled();
  });

  test("normalizes a leading slash from Windows file URIs", async () => {
    const context = createOptions({
      uri: "file:///C:/work/src/Service.java",
      filePath: "/C:/work/src/Service.java",
      range,
    });

    await openLspNavigationLocation(context.options);

    expect(context.readFileContent).toHaveBeenCalledWith("C:/work/src/Service.java");
  });

  test("reuses an open Windows buffer across separator and drive-case differences", async () => {
    const existing = {
      id: "existing-buffer",
      path: "C:\\work\\src\\Service.java",
    } as PaneContent;
    const context = createOptions(
      {
        uri: "file:///c:/work/src/Service.java",
        filePath: "c:/work/src/Service.java",
        range,
      },
      [existing],
    );

    expect(await openLspNavigationLocation(context.options)).toBe("existing-buffer");
    expect(context.setActiveBuffer).toHaveBeenCalledWith("existing-buffer");
    expect(context.openContent).not.toHaveBeenCalled();
    expect(context.readFileContent).not.toHaveBeenCalled();
  });

  test("opens JDT class files as read-only Java buffers", async () => {
    const location: LspLocation = {
      uri: "jdt://contents/java.base/java/lang/String.class?=demo",
      filePath: null,
      displayPath: "java.base/java/lang/String.java",
      isReadOnly: true,
      range,
    };
    const context = createOptions(location);

    expect(await openLspNavigationLocation(context.options)).toBe("opened-buffer");
    expect(context.getVirtualDocument).toHaveBeenCalledWith("C:/work/src/Main.java", location.uri);
    expect(context.openContent).toHaveBeenCalledWith({
      type: "editor",
      path: location.uri,
      name: "String.java",
      content: "public final class String {}",
      isVirtual: true,
      readOnly: true,
      language: "java",
      lspDocument: {
        documentUri: location.uri,
        sessionFilePath: "C:/work/src/Main.java",
        languageId: "java",
      },
    });
    expect(context.readFileContent).not.toHaveBeenCalled();
  });

  test("reuses an open virtual buffer without resolving it again", async () => {
    const uri = "jdt://contents/java.base/java/lang/String.class?=demo";
    const existing = { id: "existing-buffer", path: uri } as PaneContent;
    const context = createOptions({ uri, filePath: null, range }, [existing]);

    expect(await openLspNavigationLocation(context.options)).toBe("existing-buffer");
    expect(context.setActiveBuffer).toHaveBeenCalledWith("existing-buffer");
    expect(context.getVirtualDocument).not.toHaveBeenCalled();
    expect(context.openContent).not.toHaveBeenCalled();
  });

  test("rebinds a reused virtual buffer to the current source session", async () => {
    const uri = "jdt://contents/java.base/java/lang/String.class?=demo";
    const existing = {
      id: "existing-buffer",
      type: "editor",
      path: uri,
      name: "String.java",
      content: "old source",
      savedContent: "old source",
      isDirty: false,
      isVirtual: true,
      isPinned: false,
      isPreview: false,
      isActive: false,
      readOnly: true,
      language: "java",
      lspDocument: {
        documentUri: uri,
        sessionFilePath: "C:/work/parent/src/Old.java",
        languageId: "java",
      },
      tokens: [],
    } satisfies PaneContent;
    const context = createOptions({ uri, filePath: null, range }, [existing]);

    expect(await openLspNavigationLocation(context.options)).toBe("existing-buffer");
    expect(context.getVirtualDocument).toHaveBeenCalledWith("C:/work/src/Main.java", uri);
    expect(context.updateBuffer).toHaveBeenCalledWith({
      ...existing,
      content: "public final class String {}",
      savedContent: "public final class String {}",
      isActive: false,
      lspDocument: {
        documentUri: uri,
        sessionFilePath: "C:/work/src/Main.java",
        languageId: "java",
      },
    });
    expect(context.setActiveBuffer).toHaveBeenCalledWith("existing-buffer");
    expect(context.openContent).not.toHaveBeenCalled();
  });

  test("does not open a buffer when virtual source is unavailable", async () => {
    const context = createOptions({
      uri: "jdt://contents/java.base/java/lang/String.class?=demo",
      filePath: null,
      range,
    });
    context.getVirtualDocument.mockImplementation(async () => null);

    expect(await openLspNavigationLocation(context.options)).toBeNull();
    expect(context.openContent).not.toHaveBeenCalled();
    expect(context.setActiveBuffer).not.toHaveBeenCalled();
  });
});
