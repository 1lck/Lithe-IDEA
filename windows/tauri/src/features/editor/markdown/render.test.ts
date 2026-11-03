import { expect, test } from "bun:test";
import { clearMocks, mockIPC } from "@tauri-apps/api/mocks";
import { installHappyDom } from "@/test-utils/happy-dom";
import { renderMarkdown } from "./render";

test("Markdown source crosses the central dispatcher unchanged and Core HTML is returned", async () => {
  const restoreDom = installHappyDom();
  const source = "---\r\ntitle: 中文😀\r\n---\r\n\n- [x] Done";
  mockIPC((command, payload) => {
    expect(command).toBe("platform_invoke");
    expect(payload).toEqual({ command: "markdown.render", args: { source } });
    return { html: '<p data-sourcepos="5:1-5:10">Core output</p>' };
  });
  try {
    expect(await renderMarkdown(source)).toBe('<p data-sourcepos="5:1-5:10">Core output</p>');
  } finally {
    clearMocks();
    restoreDom();
  }
});

test("Core failures propagate without a second parser fallback", async () => {
  const restoreDom = installHappyDom();
  mockIPC(() => {
    throw new Error("Core unavailable");
  });
  try {
    await expect(renderMarkdown("# source")).rejects.toThrow("Core unavailable");
  } finally {
    clearMocks();
    restoreDom();
  }
});
