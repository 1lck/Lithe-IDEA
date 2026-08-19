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

    setHtml(parsedHtml);
    if (!parsedHtml) {
      return undefined;
    }

    void highlightMarkdownCodeBlocks(parsedHtml).then((highlightedHtml) => {
      if (!cancelled) {
        setHtml(highlightedHtml);
      }
    });

    return () => {
      cancelled = true;
    };
  }, [parsedHtml]);

  return html;
}
