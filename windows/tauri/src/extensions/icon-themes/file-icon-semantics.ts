export type FileIconSemanticKind =
  | "java.class"
  | "java.interface"
  | "java.enum"
  | "java.annotation"
  | "java.record"
  | "java.exception"
  | "folder.source-root"
  | "folder.test-root"
  | "folder.resources-root"
  | "folder.test-resources-root"
  | "folder.package";

export const IDEA_ICON_THEME_ID = "idea-icons";

const IDEA_SEMANTIC_LOOKUP_NAMES: Record<FileIconSemanticKind, string> = {
  "java.class": "\0lithe:java.class",
  "java.interface": "\0lithe:java.interface",
  "java.enum": "\0lithe:java.enum",
  "java.annotation": "\0lithe:java.annotation",
  "java.record": "\0lithe:java.record",
  "java.exception": "\0lithe:java.exception",
  "folder.source-root": "\0lithe:folder.source-root",
  "folder.test-root": "\0lithe:folder.test-root",
  "folder.resources-root": "\0lithe:folder.resources-root",
  "folder.test-resources-root": "\0lithe:folder.test-resources-root",
  "folder.package": "\0lithe:folder.package",
};

export function getSemanticFileIconLookupName(
  iconThemeId: string,
  fileName: string,
  semanticKind?: FileIconSemanticKind | null,
): string {
  if (iconThemeId !== IDEA_ICON_THEME_ID || !semanticKind) return fileName;
  return IDEA_SEMANTIC_LOOKUP_NAMES[semanticKind];
}
