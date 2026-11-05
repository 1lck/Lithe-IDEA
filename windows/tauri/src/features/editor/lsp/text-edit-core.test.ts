import { describe, expect, spyOn, test } from "bun:test";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import * as native from "@/platform/tauri-core";
import { applyTextEditsToContent, type LspTextEdit } from "./workspace-edit";

const edits: LspTextEdit[] = [
  { range: { start: { line: 1, character: 0 }, end: { line: 1, character: 2 } }, newText: "批量" },
  { range: { start: { line: 0, character: 2 }, end: { line: 0, character: 4 } }, newText: "🚀" },
];

describe("Core text edit adapter", () => {
  test("forwards the whole batch with zero-based UTF-16 positions and returns Core text", async () => {
    const invoke = spyOn(native, "invoke").mockResolvedValue({ text: "中文🚀\r\n批量\r\n" });
    try {
      expect(await applyTextEditsToContent("中文😀\r\n编辑\r\n", edits)).toBe("中文🚀\r\n批量\r\n");
      expect(invoke.mock.calls).toEqual([["lsp.applyTextEdits", {
        text: "中文😀\r\n编辑\r\n",
        edits: [
          { range: { start: { line: 1, utf16Column: 0 }, end: { line: 1, utf16Column: 2 } }, newText: "批量" },
          { range: { start: { line: 0, utf16Column: 2 }, end: { line: 0, utf16Column: 4 } }, newText: "🚀" },
        ],
      }]]);
    } finally { invoke.mockRestore(); }
  });

  test("propagates a Core rejection instead of applying a local fallback", async () => {
    const failure = Object.assign(new Error("invalidRange"), { code: "invalid_request", details: "invalidRange" });
    const invoke = spyOn(native, "invoke").mockRejectedValue(failure);
    try {
      const invalid = [{ range: { start: { line: 99, character: 0 }, end: { line: 99, character: 0 } }, newText: "bad" }];
      await expect(applyTextEditsToContent("unchanged", invalid)).rejects.toBe(failure);
    } finally { invoke.mockRestore(); }
  });
});

for (const language of ["zh-CN", "en-US"] as const) {
  test(`structured Core range errors follow a switch to ${language}`, async () => {
    const previousSettings = useSettingsStore.getState().settings;
    const invoke = spyOn(native, "invoke");
    try {
      useSettingsStore.setState({ settings: { ...previousSettings, displayLanguage: language } });
      for (const details of ["invalidRange", "overlappingEdits"] as const) {
        invoke.mockResolvedValue({
          editError: { code: "invalid_request", details, message: "English implementation detail" },
        });
        const message = language === "zh-CN"
          ? details === "invalidRange" ? "语言服务器返回了无效的文本范围。" : "语言服务器返回了重叠的文本编辑。"
          : details === "invalidRange" ? "Language server returned an invalid text range." : "Language server returned overlapping text edits.";
        await expect(applyTextEditsToContent("abc", [])).rejects.toMatchObject({
          message, code: "invalid_request", details,
        });
      }
    } finally {
      useSettingsStore.setState({ settings: previousSettings });
      invoke.mockRestore();
    }
  });
}
