import { invoke } from "@/platform/tauri-core";

/** Core owns the Markdown dialect, front matter handling and HTML sanitization. */
export async function renderMarkdown(source: string): Promise<string> {
  const result = await invoke<{ html: string }>("markdown.render", { source });
  return result.html;
}
