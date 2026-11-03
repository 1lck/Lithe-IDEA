import { expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { LocaleProvider } from "@/i18n/locale-provider";
import { installHappyDom } from "@/test-utils/happy-dom";
import { useHighlightedMarkdown } from "./use-highlighted-markdown";

function controlledOperation() {
  const calls: Array<{ input: string; resolve: (html: string) => void; reject: () => void }> = [];
  const run = (input: string) =>
    new Promise<string>((resolve, reject) => {
      calls.push({ input, resolve, reject: () => reject(new Error("test failure")) });
    });
  const releaseAll = () => {
    for (const call of calls) call.resolve(call.input);
  };
  return { run, calls, releaseAll };
}

async function withPreview(
  scenario: (probe: {
    update: (source: string) => Promise<void>;
    unmount: () => Promise<void>;
    rendered: string[];
    render: ReturnType<typeof controlledOperation>;
    highlight: ReturnType<typeof controlledOperation>;
  }) => Promise<void>,
) {
  const restoreDom = installHappyDom();
  const environment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
  const previousAct = environment.IS_REACT_ACT_ENVIRONMENT;
  const host = document.createElement("div");
  const rendered: string[] = [];
  const render = controlledOperation();
  const highlight = controlledOperation();
  let root: Root | undefined;
  function Probe({ source }: { source: string }) {
    const html = useHighlightedMarkdown(source, highlight.run, render.run);
    if (rendered[rendered.length - 1] !== html) rendered.push(html);
    return null;
  }
  const unmount = async () => {
    if (root) {
      const mounted = root;
      root = undefined;
      await act(async () => mounted.unmount());
    }
  };
  try {
    environment.IS_REACT_ACT_ENVIRONMENT = true;
    document.body.append(host);
    root = createRoot(host);
    const update = async (source: string) => {
      await act(async () =>
        root!.render(
          <LocaleProvider language="en-US">
            <Probe source={source} />
          </LocaleProvider>,
        ),
      );
    };
    await scenario({ update, unmount, rendered, render, highlight });
  } finally {
    await unmount();
    render.releaseAll();
    highlight.releaseAll();
    host.remove();
    environment.IS_REACT_ACT_ENVIRONMENT = previousAct;
    restoreDom();
  }
}

test("an edit replaces the highlighted preview once without showing plain code in between", async () => {
  await withPreview(async ({ update, rendered, render, highlight }) => {
    await update("first");
    expect(rendered).toEqual([""]);
    await act(async () => render.calls[0]!.resolve("<pre>select</pre>"));
    expect(rendered).toEqual(["", "<pre>select</pre>"]);
    await act(async () => highlight.calls[0]!.resolve("<pre><span>select</span></pre>"));
    await update("second");
    await act(async () => render.calls[1]!.resolve("<pre>delete</pre>"));
    expect(rendered[rendered.length - 1]).toBe("<pre><span>select</span></pre>");
    await act(async () => highlight.calls[1]!.resolve("<pre><span>delete</span></pre>"));
    expect(rendered).toHaveLength(4);
    expect(rendered[rendered.length - 1]).toBe("<pre><span>delete</span></pre>");
  });
});

test("an obsolete Core response cannot overwrite the current document or start highlighting", async () => {
  await withPreview(async ({ update, rendered, render, highlight }) => {
    await update("old");
    await update("new");
    await act(async () => render.calls[1]!.resolve("<p>new</p>"));
    await act(async () => highlight.calls[0]!.resolve("<p>new ready</p>"));
    await act(async () => render.calls[0]!.resolve("<p>old</p>"));
    expect(rendered[rendered.length - 1]).toBe("<p>new ready</p>");
    expect(highlight.calls).toHaveLength(1);
  });
});

test("obsolete highlighting cannot overwrite a newer preview", async () => {
  await withPreview(async ({ update, rendered, render, highlight }) => {
    await update("old");
    await act(async () => render.calls[0]!.resolve("<p>old</p>"));
    await update("new");
    await act(async () => render.calls[1]!.resolve("<p>new</p>"));
    await act(async () => highlight.calls[1]!.resolve("<p>new ready</p>"));
    await act(async () => highlight.calls[0]!.resolve("<p>old ready</p>"));
    expect(rendered[rendered.length - 1]).toBe("<p>new ready</p>");
  });
});

test("clearing and unmounting discard pending renders", async () => {
  await withPreview(async ({ update, unmount, rendered, render, highlight }) => {
    await update("old");
    await update("");
    await act(async () => render.calls[0]!.resolve("<p>old</p>"));
    expect(rendered[rendered.length - 1]).toBe("");
    expect(highlight.calls).toHaveLength(0);
    await update("closing");
    await unmount();
    await act(async () => render.calls[1]!.resolve("<p>closing</p>"));
    expect(highlight.calls).toHaveLength(0);
  });
});

test("Core failure shows a localized diagnostic and the next edit can recover", async () => {
  await withPreview(async ({ update, rendered, render, highlight }) => {
    await update("bad");
    await act(async () => render.calls[0]!.reject());
    expect(rendered[rendered.length - 1]).toContain('role="alert"');
    expect(rendered[rendered.length - 1]).toContain("Edit or reopen the document");
    await update("fixed");
    await act(async () => render.calls[1]!.resolve("<p>fixed</p>"));
    await act(async () => highlight.calls[0]!.resolve("<p>fixed ready</p>"));
    expect(rendered[rendered.length - 1]).toBe("<p>fixed ready</p>");
  });
});

test("highlighter failure preserves sanitized Core HTML", async () => {
  await withPreview(async ({ update, rendered, render, highlight }) => {
    await update("plain");
    await act(async () => render.calls[0]!.resolve("<p>safe</p>"));
    await act(async () => highlight.calls[0]!.reject());
    expect(rendered[rendered.length - 1]).toBe("<p>safe</p>");
  });
});
