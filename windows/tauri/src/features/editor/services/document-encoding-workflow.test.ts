import { describe, expect, test } from "bun:test";
import { reopenDocumentWithEncoding } from "./document-encoding-workflow";
import type { EditorContent } from "@/features/panes/types/pane-content.types";
import type { DocumentReadDetails } from "@/platform/document-files";

function document(overrides: Partial<EditorContent> = {}): EditorContent {
  return {
    id: "buffer-a",
    type: "editor",
    path: "/workspace/readme.txt",
    name: "readme.txt",
    content: "中文",
    savedContent: "中文",
    isDirty: false,
    documentLifecycle: { status: "clean", revision: 2 },
    isVirtual: false,
    isPinned: false,
    isPreview: false,
    isActive: true,
    encoding: "UTF-8",
    diskIdentity: "old",
    tokens: [],
    contentRevision: 2,
    ...overrides,
  };
}

const details: DocumentReadDetails = {
  content: "中文",
  encoding: "GBK",
  identity: "new",
};

describe("document encoding workflow", () => {
  test("discards dirty content and commits only the captured disk snapshot", async () => {
    let current = document({ content: "未保存", isDirty: true, documentLifecycle: { status: "dirty", revision: 3, savedRevision: 2 }, contentRevision: 3 });
    let replaced = false;
    const result = await reopenDocumentWithEncoding("GBK", {
      snapshot: () => current,
      isCurrent: () => true,
      chooseDirtyAction: async () => "discard",
      save: async () => "saved",
      read: async () => details,
      replace: (source, next) => {
        expect(source.content).toBe("未保存");
        current = document({ content: next.content, encoding: next.encoding, diskIdentity: next.identity });
        replaced = true;
        return true;
      },
    });
    expect(result).toBe(true);
    expect(replaced).toBe(true);
    expect(current.encoding).toBe("GBK");
  });

  test("rejects a read that completes after the buffer changed", async () => {
    let current = document();
    let releaseRead!: (value: DocumentReadDetails) => void;
    const read = new Promise<DocumentReadDetails>((resolve) => { releaseRead = resolve; });
    const operation = reopenDocumentWithEncoding("GBK", {
      snapshot: () => current,
      isCurrent: () => true,
      chooseDirtyAction: async () => null,
      save: async () => "saved",
      read: async () => read,
      replace: () => {
        throw new Error("stale replacement");
      },
    });
    current = document({ content: "new edit", contentRevision: 3, isDirty: true, documentLifecycle: { status: "dirty", revision: 3, savedRevision: 2 } });
    releaseRead(details);
    expect(await operation).toBe(false);
  });
});
