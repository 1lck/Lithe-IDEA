// Regenerates the token goldens of desktop/internal/editor/textmate/testdata with the reference
// engine, vscode-textmate 9.3.2 on vscode-oniguruma 1.7.0. TestMatchesVSCodeTextMate compares the
// Go tokenizer with these files token by token.
//
// Usage:
//   npm install --prefix <dir> vscode-textmate@9.3.2 vscode-oniguruma@1.7.0
//   node scripts/desktop/generate-textmate-goldens.mjs <dir>
//
// <dir> is any directory outside the repository; the script only reads the packages from it.
// Each golden has one JSON array per input line: [[startIndexUTF16, "scope scope ..."], ...].
import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const [packages] = process.argv.slice(2);
if (!packages) {
  console.error("Usage: node scripts/desktop/generate-textmate-goldens.mjs <dir with vscode-textmate>");
  process.exit(2);
}
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const grammarDir = path.join(root, "desktop/internal/editor/syntax/grammars");
const testdata = path.join(root, "desktop/internal/editor/textmate/testdata");
// The same samples and scopes as TestMatchesVSCodeTextMate.
const samples = {
  "Sample.java": "source.java",
  "Makefile": "source.makefile",
  "CMakeLists.txt": "source.cmake",
  "build.gradle": "source.groovy",
};

const require = createRequire(path.join(path.resolve(packages), "package.json"));
const vsctm = require("vscode-textmate");
const onig = require("vscode-oniguruma");
await onig.loadWASM(fs.readFileSync(require.resolve("vscode-oniguruma/release/onig.wasm")).buffer);

const grammars = {};
for (const file of fs.readdirSync(grammarDir).filter((name) => name.endsWith(".tmLanguage.json"))) {
  const text = fs.readFileSync(path.join(grammarDir, file), "utf8");
  grammars[JSON.parse(text).scopeName] = { text, file: path.join(grammarDir, file) };
}
const registry = new vsctm.Registry({
  onigLib: Promise.resolve({
    createOnigScanner: (patterns) => new onig.OnigScanner(patterns),
    createOnigString: (text) => new onig.OnigString(text),
  }),
  loadGrammar: async (scope) =>
    grammars[scope] ? vsctm.parseRawGrammar(grammars[scope].text, grammars[scope].file) : null,
});

for (const [name, scope] of Object.entries(samples)) {
  const grammar = await registry.loadGrammar(scope);
  let state = vsctm.INITIAL;
  const lines = [];
  for (const line of fs.readFileSync(path.join(testdata, name), "utf8").split(/\r\n|\r|\n/)) {
    const result = grammar.tokenizeLine(line, state, 0);
    lines.push(JSON.stringify(result.tokens.map((token) => [token.startIndex, token.scopes.join(" ")])));
    state = result.ruleStack;
  }
  fs.writeFileSync(path.join(testdata, `${name}.tokens`), lines.join("\n") + "\n");
  console.log(`${name}.tokens: ${lines.length} lines`);
}
