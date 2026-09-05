import type { EditorContent, PaneContent } from "@/features/panes/types/pane-content.types";

export function isMarkdownPreviewableFile(filePath: string): boolean {
  const extension = filePath.split(".").pop()?.toLowerCase();
  return extension === "md" || extension === "markdown" || extension === "rmd";
}

/** Whether the buffer is a plain text editor buffer whose path is a Markdown file. */
export function isMarkdownEditorBuffer(
  buffer: PaneContent | null | undefined,
): buffer is EditorContent {
  return buffer?.type === "editor" && isMarkdownPreviewableFile(buffer.path);
}
