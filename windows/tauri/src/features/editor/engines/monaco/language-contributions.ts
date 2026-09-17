import { typescript } from "monaco-editor";
import "monaco-editor/esm/vs/language/css/monaco.contribution";
import "monaco-editor/esm/vs/language/html/monaco.contribution";
import "monaco-editor/esm/vs/language/json/monaco.contribution";
import "monaco-editor/esm/vs/language/typescript/monaco.contribution";

const jsxCompilerOptions = {
  jsx: typescript.JsxEmit.Preserve,
} satisfies typescript.CompilerOptions;

const lspOwnedDiagnosticsOptions = {
  noSemanticValidation: true,
  noSuggestionDiagnostics: true,
} satisfies typescript.DiagnosticsOptions;

typescript.typescriptDefaults.setCompilerOptions({
  ...typescript.typescriptDefaults.getCompilerOptions(),
  ...jsxCompilerOptions,
});
typescript.typescriptDefaults.setDiagnosticsOptions(lspOwnedDiagnosticsOptions);

typescript.javascriptDefaults.setCompilerOptions({
  ...typescript.javascriptDefaults.getCompilerOptions(),
  ...jsxCompilerOptions,
});
typescript.javascriptDefaults.setDiagnosticsOptions(lspOwnedDiagnosticsOptions);

import { ensureMonacoLanguageTokenizer as ensureBasicTokenizer } from "@lithe/editor/language-contributions";
import { ensureJavaTextMate } from "./java-textmate";

export { prewarmCommonLanguageTokenizers } from "@lithe/editor/language-contributions";

export async function ensureMonacoLanguageTokenizer(languageId: string): Promise<boolean> {
  const registered = await ensureBasicTokenizer(languageId);
  if (languageId === "java") await ensureJavaTextMate();
  return registered;
}
