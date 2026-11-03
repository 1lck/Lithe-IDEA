import { afterAll, expect, test } from "bun:test";
import { CString, dlopen, FFIType } from "bun:ffi";
import { clearMocks, mockIPC } from "@tauri-apps/api/mocks";
import fixture from "../../../../../../shared/fixtures/editor/markdown-render-v1.json";
import { installHappyDom } from "@/test-utils/happy-dom";
import { highlightMarkdownCodeBlocks } from "./code-highlight";
import { renderMarkdown } from "./render";

const libraryPath = process.env.LITHE_CORE_TEST_LIBRARY;
const library = libraryPath
  ? dlopen(libraryPath, {
      lithe_core_execute_json: { args: [FFIType.ptr], returns: FFIType.ptr },
      lithe_core_free_string: { args: [FFIType.ptr], returns: FFIType.void },
    })
  : null;
afterAll(() => library?.close());

for (const item of fixture.cases) {
  test.skipIf(!library)(
    `native Core Markdown -> platform dispatcher -> preview: ${item.name}`,
    async () => {
      const restoreDom = installHappyDom();
      const calls: string[] = [];
      mockIPC((command, payload) => {
      if (!payload || Array.isArray(payload) || payload instanceof ArrayBuffer || payload instanceof Uint8Array) {
          throw new Error("Expected dispatcher payload");
        }
        expect(command).toBe("platform_invoke");
        expect(payload.command).toBe("markdown.render");
        expect(payload.args).toEqual({ source: item.source });
        calls.push(command);
        const input = Buffer.from(
          JSON.stringify({ id: "markdown", command: payload.command, payload: payload.args }) +
            "\0",
        );
        const pointer = library!.symbols.lithe_core_execute_json(input);
        if (!pointer) throw new Error("Core returned null");
        try {
          const response = JSON.parse(new CString(pointer).toString());
          if (!response.ok) throw new Error(response.error.message);
          return response.data;
        } finally {
          library!.symbols.lithe_core_free_string(pointer);
        }
      });
      try {
        const html = await renderMarkdown(item.source);
        for (const fragment of item.contains) expect(html).toContain(fragment);
        for (const fragment of item.absent) expect(html).not.toContain(fragment);
        const highlighted = await highlightMarkdownCodeBlocks(html);
        const host = document.createElement("div");
        host.innerHTML = highlighted;
        expect(host.querySelector("script, style, iframe, object")).toBeNull();
        expect(host.querySelector("[onclick], [onerror]")).toBeNull();
        if (item.name.startsWith("fenced code")) {
          expect(host.querySelector("code")?.textContent).toBe(
            "  select '<script>中文😀</script>', '$&';\n\n",
          );
          expect(host.querySelector(".token-keyword")).not.toBeNull();
          expect(host.querySelector("pre")?.hasAttribute("data-sourcepos")).toBe(true);
        }
        expect(calls).toEqual(["platform_invoke"]);
      } finally {
        clearMocks();
        restoreDom();
      }
    },
  );
}
