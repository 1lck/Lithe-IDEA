import { expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { LocaleProvider } from "@/i18n/locale-provider";
import { installHappyDom } from "@/test-utils/happy-dom";

const settle = () => new Promise((resolve) => setTimeout(resolve, 0));

test("an edit replaces the highlighted preview once, without showing plain code in between", async () => {
  const restoreDom = installHappyDom();
  // DOMPurify binds to the window it finds on first import.
  const { useHighlightedMarkdown } = await import("./use-highlighted-markdown");
  const environment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
  const previousAct = environment.IS_REACT_ACT_ENVIRONMENT;
  const host = document.createElement("div");
  const rendered: string[] = [];
  let root: Root | undefined;
  function Probe({ content }: { content: string }) {
    const html = useHighlightedMarkdown(content);
    if (rendered[rendered.length - 1] !== html) rendered.push(html);
    return null;
  }
  const render = (content: string) => (
    <LocaleProvider language="en-US">
      <Probe content={content} />
    </LocaleProvider>
  );
  try {
    environment.IS_REACT_ACT_ENVIRONMENT = true;
    document.body.append(host);
    root = createRoot(host);
    const mountedRoot = root;

    await act(async () => mountedRoot.render(render("# Notes\n\n```sql\nselect 1\n```\n")));
    await act(settle);
    // The first render shows the document before highlighting finishes.
    expect(rendered).toHaveLength(2);
    expect(rendered[0]).not.toContain("token-keyword");
    expect(rendered[1]).toContain('<span class="token-keyword">select</span>');

    await act(async () => mountedRoot.render(render("# Notes\n\n```sql\ndelete from t\n```\n")));
    await act(settle);
    expect(rendered).toHaveLength(3);
    expect(rendered[2]).toContain('<span class="token-keyword">delete</span>');

    await act(async () => mountedRoot.render(render("")));
    expect(rendered[rendered.length - 1]).toBe("");
  } finally {
    if (root) await act(async () => root!.unmount());
    host.remove();
    environment.IS_REACT_ACT_ENVIRONMENT = previousAct;
    restoreDom();
  }
});
