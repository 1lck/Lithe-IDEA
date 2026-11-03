import { installTextMate, type TextMateResources } from "./textmate";

const scopes: Record<string, string> = {
  makefile: "source.makefile", cmake: "source.cmake", groovy: "source.groovy",
};
const installations = new Map<string, Promise<Awaited<ReturnType<typeof installTextMate>>>>();
let generation = 0;

/** Load only opened languages; workers and registrations belong to this WebView. */
export function ensureBasicTextMate(language: string, resources?: TextMateResources): Promise<boolean> | undefined {
  const scope = scopes[language];
  if (!scope) return undefined;
  let pending = installations.get(language);
  if (!pending) {
    const current = generation;
    pending = installTextMate(language, scope, resources).then(tokenizer => {
      if (current !== generation) {
        tokenizer.dispose();
        throw new Error(`Tokenizer initialization was cancelled: ${language}`);
      }
      return tokenizer;
    });
    installations.set(language, pending);
    const owned = pending;
    void pending.catch(() => { if (installations.get(language) === owned) installations.delete(language); });
  }
  return pending.then(() => true);
}

function dispose() {
  generation++;
  for (const pending of installations.values()) void pending.then(tokenizer => tokenizer.dispose(), () => undefined);
  installations.clear();
}
if (typeof window !== "undefined") window.addEventListener("pagehide", dispose);
if (import.meta.hot) import.meta.hot.dispose(() => {
  if (typeof window !== "undefined") window.removeEventListener("pagehide", dispose);
  dispose();
});
