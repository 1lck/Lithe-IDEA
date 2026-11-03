import { useEffect, useState } from "react";
import { useTranslation } from "@/i18n/locale-provider";
import { highlightMarkdownCodeBlocks } from "./code-highlight";
import { renderMarkdownWhenReady } from "./render";

export function useHighlightedMarkdown(
  content: string | null | undefined,
  highlight: (html: string) => Promise<string> = highlightMarkdownCodeBlocks,
  render: (source: string, signal?: AbortSignal) => Promise<string> = renderMarkdownWhenReady,
) {
  const { t } = useTranslation();
  const [html, setHtml] = useState("");

  useEffect(() => {
    let cancelled = false;
    const controller = new AbortController();
    if (!content) {
      setHtml("");
      return;
    }

    void render(content, controller.signal).then(
      async (parsedHtml) => {
        if (cancelled) return;
        // Preserve the last highlighted preview until this edit is ready.
        // Only the first document shows plain HTML while highlighting.
        setHtml((current) => current || parsedHtml);
        let nextHtml = parsedHtml;
        try {
          nextHtml = await highlight(parsedHtml);
        } catch {
          // Core's sanitized HTML remains usable without syntax highlighting.
        }
        if (!cancelled) setHtml(nextHtml);
      },
      () => {
        if (cancelled) return;
        // Localized diagnostics are text, never trusted HTML.
        const message = document.createElement("p");
        message.setAttribute("role", "alert");
        message.textContent = t("markdown.renderFailed");
        setHtml(message.outerHTML);
      },
    );

    return () => {
      cancelled = true;
      controller.abort();
    };
  }, [content, highlight, render, t]);

  return html;
}
