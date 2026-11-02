export interface ThoughtSection {
  title: string | null;
  body: string;
  isTitleComplete: boolean;
}

/** Reasoning headings and Markdown bodies are presentation, never stored edits. */
export function thoughtSections(source: string, isStreaming = false, usesSummaryHeadings = true): ThoughtSection[] {
  if (!usesSummaryHeadings) return source.trim() === "" ? [] : [{ title: null, body: source, isTitleComplete: true }];
  const sections: ThoughtSection[] = [];
  let title: string | null = null;
  let body = "";
  let isTitleComplete = true;
  let fence: { marker: string; count: number } | undefined;
  const lines = source.split("\n");
  const flush = () => {
    if (title !== null || body.trim() !== "") sections.push({ title, body: body.replace(/^[\r\n]+|[\r\n]+$/g, ""), isTitleComplete });
    title = null;
    body = "";
    isTitleComplete = true;
  };
  lines.forEach((line, index) => {
    const indented = line.startsWith("    ") || line.startsWith("\t");
    const trimmed = line.trim();
    const opening = indented ? undefined : /^(`{3,}|~{3,})/.exec(trimmed)?.[0];
    if (opening !== undefined) {
      if (fence === undefined) fence = { marker: opening[0], count: opening.length };
      else if (opening[0] === fence.marker && opening.length >= fence.count && trimmed.slice(opening.length).trim() === "") fence = undefined;
    }
    let remainder = line;
    if (!indented && opening === undefined && fence === undefined && (index === 0 || lines[index - 1].trim() === "")) {
      let candidate = trimmed;
      while (candidate.startsWith("**")) {
        const afterOpen = candidate.slice(2);
        const close = afterOpen.indexOf("**");
        const draft = isStreaming && index === lines.length - 1 && close < 0;
        const heading = close >= 0 ? afterOpen.slice(0, close) : draft && afterOpen.endsWith("*") ? afterOpen.slice(0, -1) : afterOpen;
        if (draft && heading === "") { remainder = ""; break; }
        if (heading === "" || heading !== heading.trim() || /[*`\\\[\]<>_&]/.test(heading)
          || (close < 0 && !draft)) break;
        flush();
        title = heading;
        isTitleComplete = close >= 0;
        candidate = close < 0 ? "" : afterOpen.slice(close + 2);
        remainder = candidate.trim();
        if (isStreaming && index === lines.length - 1 && candidate === "*") remainder = "";
      }
    }
    body += remainder + (index < lines.length - 1 ? "\n" : "");
  });
  flush();
  return sections;
}

export function currentThoughtTitle(source: string): string | null {
  const sections = thoughtSections(source, true);
  for (let index = sections.length - 1; index >= 0; index--) {
    if (sections[index].title !== null && sections[index].isTitleComplete) return sections[index].title;
  }
  return null;
}
