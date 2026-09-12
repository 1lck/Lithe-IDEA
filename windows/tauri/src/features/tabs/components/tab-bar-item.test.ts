import { expect, test } from "bun:test";

test("editor tabs pass Java declaration semantics to the active icon theme", async () => {
  const source = await Bun.file(new URL("./tab-bar-item.tsx", import.meta.url)).text();

  expect(source).toContain(
    'import { useJavaFileIconKind } from "@/extensions/icon-themes/hooks/use-java-file-icon-kind";',
  );
  expect(source).toContain('buffer.type === "editor" && !buffer.isVirtual');
  expect(source).toContain("semanticKind={javaSemanticKind}");
});

test("editor tabs close when the middle mouse button is released", async () => {
  const source = await Bun.file(new URL("./tab-bar-item.tsx", import.meta.url)).text();

  expect(source).toContain("const handleAuxClick = useCallback(");
  expect(source).toContain("if (e.button !== 1) return;");
  expect(source).toContain("handleTabClose(buffer.id);");
  expect(source).toContain("onAuxClick={handleAuxClick}");
});
