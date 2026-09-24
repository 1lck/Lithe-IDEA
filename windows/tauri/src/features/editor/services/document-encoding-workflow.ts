import type { EditorContent } from "@/features/panes/types/pane-content.types";
import { isLocalDocumentPath, type DocumentReadDetails, type FileEncoding } from "@/platform/document-files";

export function canReopenWithEncoding(buffer: EditorContent): boolean {
  return !buffer.isVirtual && isLocalDocumentPath(buffer.path) &&
    buffer.documentLifecycle?.status !== "saving" && buffer.loadState !== "loading";
}

export function canSaveWithEncoding(buffer: EditorContent): boolean {
  return canReopenWithEncoding(buffer) && !buffer.readOnly &&
    (!buffer.loadState || buffer.loadState === "loaded") && buffer.documentLifecycle?.status !== "conflict";
}

interface ReopenOwner {
  snapshot: () => EditorContent | null;
  isCurrent: () => boolean;
  chooseDirtyAction: () => Promise<"save" | "discard" | null>;
  save: () => Promise<string>;
  read: (path: string, encoding: FileEncoding) => Promise<DocumentReadDetails | null>;
  replace: (source: EditorContent, details: DocumentReadDetails) => boolean;
}

function sameDocument(left: EditorContent, right: EditorContent | null): boolean {
  return !!right && left.id === right.id && left.path === right.path &&
    left.contentRevision === right.contentRevision && left.content === right.content &&
    (left.readEncoding ?? left.encoding) === (right.readEncoding ?? right.encoding) &&
    (left.saveEncoding ?? left.readEncoding ?? left.encoding) === (right.saveEncoding ?? right.readEncoding ?? right.encoding) &&
    left.diskIdentity === right.diskIdentity &&
    left.documentLifecycle?.status === right.documentLifecycle?.status;
}

/** Every awaited choice/read authorizes only its captured document snapshot. */
export async function reopenDocumentWithEncoding(encoding: FileEncoding, owner: ReopenOwner): Promise<boolean> {
  let source = owner.snapshot();
  if (!source || !owner.isCurrent() || !canReopenWithEncoding(source)) return false;
  if (source.isDirty) {
    const choice = await owner.chooseDirtyAction();
    if (!choice || !owner.isCurrent() || !sameDocument(source, owner.snapshot())) return false;
    if (choice === "save") {
      if (await owner.save() !== "saved" || !owner.isCurrent()) return false;
      const saved = owner.snapshot();
      if (!saved || saved.id !== source.id || saved.path !== source.path || saved.isDirty) return false;
      source = saved;
    }
  }
  const details = await owner.read(source.path, encoding);
  if (!details) throw new Error("File no longer exists");
  if (!owner.isCurrent() || !sameDocument(source, owner.snapshot())) return false;
  return owner.replace(source, details);
}
