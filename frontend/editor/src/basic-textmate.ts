import { installTextMate, TextMateInstallationCancelled, type TextMateResources } from "./textmate";
import { hasPluginGrammar } from "./plugin-languages";

const scopes: Record<string, string> = {
  makefile: "source.makefile", cmake: "source.cmake", groovy: "source.groovy",
};
const installations = new Map<string, Promise<Awaited<ReturnType<typeof installTextMate>> | undefined>>();
let generation = 0;

/** Load only opened languages; workers and registrations belong to this WebView. */
export function ensureBasicTextMate(language: string, resources?: TextMateResources): Promise<boolean> | undefined {
  const scope = scopes[language];
  if (!scope) return undefined;
  if (hasPluginGrammar(language)) return Promise.resolve(true);
  let pending = installations.get(language);
  if (!pending) {
    const current = generation;
    pending = installTextMate(language, scope, resources, () => current === generation && !hasPluginGrammar(language))
      .catch(error => {
        if (installations.get(language) === owned) installations.delete(language);
        if (error instanceof TextMateInstallationCancelled) return undefined;
        throw error;
      });
    installations.set(language, pending);
    const owned = pending;
  }
  return pending.then(() => true);
}

function dispose() {
  generation++;
  for (const pending of installations.values()) void pending.then(tokenizer => tokenizer?.dispose(), () => undefined);
  installations.clear();
}
if (typeof window !== "undefined") window.addEventListener("pagehide", dispose);
if (import.meta.hot) import.meta.hot.dispose(() => {
  if (typeof window !== "undefined") window.removeEventListener("pagehide", dispose);
  dispose();
});
