import { expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { LocaleProvider } from "@/i18n/locale-provider";
import { installHappyDom } from "@/test-utils/happy-dom";

/** Highlighter whose calls the test completes, in the order it chooses. */
function controlledHighlighter() {
  const pending: Array<{ html: string; resolve: (html: string) => void; done: Promise<string> }> = [];
  const highlight = (html: string) => {
    let resolve!: (html: string) => void;
    const done = new Promise<string>((settle) => {
      resolve = settle;
    });
    pending.push({ html, resolve, done });
    return done;
  };
  // Marks the code as highlighted the way the real highlighter's output would.
  const finish = async () => {
    const call = pending.shift();
    if (!call) throw new Error("No highlight is pending");
    call.resolve(call.html.replace(/\b(select|delete)\b/, '<span class="token-keyword">$1</span>'));
    await call.done;
  };
  // Teardown releases work an assertion failure left pending.
  const releaseAll = () => {
    for (const call of pending.splice(0)) call.resolve(call.html);
  };
  return { highlight, finish, releaseAll, pending };
}

test("an edit replaces the highlighted preview once, without showing plain code in between", async () => {
  const restoreDom = installHappyDom();
  // DOMPurify binds to the window it finds on first import.
  const { useHighlightedMarkdown } = await import("./use-highlighted-markdown");
  const environment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
  const previousAct = environment.IS_REACT_ACT_ENVIRONMENT;
  const host = document.createElement("div");
  const rendered: string[] = [];
  const highlighter = controlledHighlighter();
  let root: Root | undefined;
  function Probe({ content }: { content: string }) {
    const html = useHighlightedMarkdown(content, undefined, highlighter.highlight);
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
    await act(highlighter.finish);
    // The first render shows the document before highlighting finishes.
    expect(rendered).toHaveLength(2);
    expect(rendered[0]).not.toContain("token-keyword");
    expect(rendered[1]).toContain('<span class="token-keyword">select</span>');

    await act(async () => mountedRoot.render(render("# Notes\n\n```sql\ndelete from t\n```\n")));
    // While the edit is being highlighted, the previous highlighted preview stays.
    expect(rendered).toHaveLength(2);
    await act(highlighter.finish);
    expect(rendered).toHaveLength(3);
    expect(rendered[2]).toContain('<span class="token-keyword">delete</span>');

    await act(async () => mountedRoot.render(render("")));
    expect(rendered[rendered.length - 1]).toBe("");
    expect(highlighter.pending).toHaveLength(0);
  } finally {
    highlighter.releaseAll();
    if (root) await act(async () => root!.unmount());
    host.remove();
    environment.IS_REACT_ACT_ENVIRONMENT = previousAct;
    restoreDom();
  }
});
