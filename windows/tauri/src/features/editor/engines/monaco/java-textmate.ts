type JavaTokenizer = Awaited<ReturnType<typeof import("@lithe/editor/textmate-bundled").installBundledJavaTextMate>>;

let installation: Promise<JavaTokenizer> | undefined;
let generation = 0;

/** One shared registration/worker serves every retained Java model in this WebView. */
export function ensureJavaTextMate(): Promise<void> {
  if (!installation) {
    const current = generation;
    const pending = import("@lithe/editor/textmate-bundled")
      .then(({ installBundledJavaTextMate }) => installBundledJavaTextMate())
      .then((tokenizer) => {
        if (generation !== current) {
          tokenizer.dispose();
          throw new Error("Java tokenizer initialization was cancelled");
        }
        return tokenizer;
      });
    installation = pending;
    void pending.catch(() => {
      if (installation === pending) installation = undefined;
    });
  }
  return installation.then(() => undefined);
}

function disposeJavaTextMate() {
  generation++;
  const previous = installation;
  installation = undefined;
  // Initialization failures already reach the editor's tokenizer error handler.
  void previous?.then((tokenizer) => tokenizer.dispose(), () => undefined);
}

if (typeof window !== "undefined") window.addEventListener("pagehide", disposeJavaTextMate);
if (import.meta.hot) {
  import.meta.hot.dispose(() => {
    if (typeof window !== "undefined") window.removeEventListener("pagehide", disposeJavaTextMate);
    disposeJavaTextMate();
  });
}
