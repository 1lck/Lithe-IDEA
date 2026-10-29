import { useEffect, useMemo, useState } from "react";
import { useTranslation } from "@/i18n/locale-provider";
import { highlightMarkdownCodeBlocks } from "./code-highlight";
import { parseMarkdown, type ParseMarkdownOptions } from "./parser";

export function useHighlightedMarkdown(
  content: string | null | undefined,
  options?: ParseMarkdownOptions,
) {
  const { t } = useTranslation();
  const frontMatter = options?.frontMatter;
  const parsedHtml = useMemo(() => {
    if (!content) return "";
    return parseMarkdown(content, { frontMatter, frontMatterLabel: t("markdown.documentProperties") });
  }, [content, frontMatter, t]);
  const [html, setHtml] = useState(parsedHtml);

  useEffect(() => {
    let cancelled = false;

    if (!parsedHtml) {
      setHtml(parsedHtml);
      return undefined;
    }
    // Keep the current preview until the edited document is highlighted too.
    // Showing the plain HTML in between rebuilt and laid out the whole preview
    // twice per edit; only an empty preview shows it first.
    setHtml((current) => current || parsedHtml);

    void highlightMarkdownCodeBlocks(parsedHtml).then(
      (highlightedHtml) => {
        if (!cancelled) {
          setHtml(highlightedHtml);
        }
      },
      () => {
        if (!cancelled) {
          setHtml(parsedHtml);
        }
      },
    );

    return () => {
      cancelled = true;
    };
  }, [parsedHtml]);

  return html;
}
