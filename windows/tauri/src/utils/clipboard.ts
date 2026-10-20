export async function readClipboardText(): Promise<string> {
  try {
    const { readText } = await import("@tauri-apps/plugin-clipboard-manager");
    return await readText();
  } catch {
    const readText = globalThis.navigator?.clipboard?.readText;
    if (!readText) {
      throw new Error("Clipboard read API is unavailable.");
    }
    return readText.call(globalThis.navigator.clipboard);
  }
}

export async function writeClipboardText(text: string): Promise<void> {
  try {
    const { writeText } = await import("@tauri-apps/plugin-clipboard-manager");
    await writeText(text);
  } catch {
    const writeText = globalThis.navigator?.clipboard?.writeText;
    if (!writeText) {
      throw new Error("Clipboard write API is unavailable.");
    }
    await writeText.call(globalThis.navigator.clipboard, text);
  }
}

/**
 * Write real `text/html` plus a plain-text fallback. The Tauri clipboard
 * plugin only carries text, so HTML tables need the WebView clipboard API to
 * paste as cells instead of markup source.
 */
export async function writeClipboardHtml(html: string, text: string): Promise<void> {
  const clipboard = globalThis.navigator?.clipboard;
  const ClipboardItemConstructor = globalThis.ClipboardItem;
  if (clipboard?.write !== undefined && ClipboardItemConstructor !== undefined) {
    try {
      await clipboard.write([
        new ClipboardItemConstructor({
          "text/html": new Blob([html], { type: "text/html" }),
          "text/plain": new Blob([text], { type: "text/plain" }),
        }),
      ]);
      return;
    } catch {
      // Fall through to the plain-text adapter below.
    }
  }
  await writeClipboardText(text);
}

export async function tryWriteClipboardText(text: string): Promise<boolean> {
  try {
    await writeClipboardText(text);
    return true;
  } catch {
    return false;
  }
}
