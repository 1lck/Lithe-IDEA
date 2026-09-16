import { languages } from "monaco-editor/esm/vs/editor/editor.api.js";

import "monaco-editor/esm/vs/basic-languages/cpp/cpp.contribution.js";
import "monaco-editor/esm/vs/basic-languages/css/css.contribution.js";
import "monaco-editor/esm/vs/basic-languages/csharp/csharp.contribution.js";
import "monaco-editor/esm/vs/basic-languages/dart/dart.contribution.js";
import "monaco-editor/esm/vs/basic-languages/dockerfile/dockerfile.contribution.js";
import "monaco-editor/esm/vs/basic-languages/elixir/elixir.contribution.js";
import "monaco-editor/esm/vs/basic-languages/go/go.contribution.js";
import "monaco-editor/esm/vs/basic-languages/graphql/graphql.contribution.js";
import "monaco-editor/esm/vs/basic-languages/hcl/hcl.contribution.js";
import "monaco-editor/esm/vs/basic-languages/html/html.contribution.js";
import "monaco-editor/esm/vs/basic-languages/java/java.contribution.js";
import "monaco-editor/esm/vs/basic-languages/javascript/javascript.contribution.js";
import "monaco-editor/esm/vs/basic-languages/kotlin/kotlin.contribution.js";
import "monaco-editor/esm/vs/basic-languages/less/less.contribution.js";
import "monaco-editor/esm/vs/basic-languages/lua/lua.contribution.js";
import "monaco-editor/esm/vs/basic-languages/markdown/markdown.contribution.js";
import "monaco-editor/esm/vs/basic-languages/objective-c/objective-c.contribution.js";
import "monaco-editor/esm/vs/basic-languages/php/php.contribution.js";
import "monaco-editor/esm/vs/basic-languages/protobuf/protobuf.contribution.js";
import "monaco-editor/esm/vs/basic-languages/python/python.contribution.js";
import "monaco-editor/esm/vs/basic-languages/r/r.contribution.js";
import "monaco-editor/esm/vs/basic-languages/ruby/ruby.contribution.js";
import "monaco-editor/esm/vs/basic-languages/rust/rust.contribution.js";
import "monaco-editor/esm/vs/basic-languages/scala/scala.contribution.js";
import "monaco-editor/esm/vs/basic-languages/scheme/scheme.contribution.js";
import "monaco-editor/esm/vs/basic-languages/scss/scss.contribution.js";
import "monaco-editor/esm/vs/basic-languages/shell/shell.contribution.js";
import "monaco-editor/esm/vs/basic-languages/solidity/solidity.contribution.js";
import "monaco-editor/esm/vs/basic-languages/sql/sql.contribution.js";
import "monaco-editor/esm/vs/basic-languages/swift/swift.contribution.js";
import "monaco-editor/esm/vs/basic-languages/typescript/typescript.contribution.js";
import "monaco-editor/esm/vs/basic-languages/xml/xml.contribution.js";
import "monaco-editor/esm/vs/basic-languages/yaml/yaml.contribution.js";
import { zigMonarchLanguage } from "./zig-language";

type MonarchLanguageModule = {
  conf: Parameters<typeof languages.setLanguageConfiguration>[1];
  language: Parameters<typeof languages.setMonarchTokensProvider>[1];
};

const monarchLanguageLoaders: Record<string, () => Promise<MonarchLanguageModule>> = {
  dotenv: () => import("monaco-editor/esm/vs/basic-languages/shell/shell.js"),
  c: () => import("monaco-editor/esm/vs/basic-languages/cpp/cpp.js"),
  cpp: () => import("monaco-editor/esm/vs/basic-languages/cpp/cpp.js"),
  css: () => import("monaco-editor/esm/vs/basic-languages/css/css.js"),
  csharp: () => import("monaco-editor/esm/vs/basic-languages/csharp/csharp.js"),
  dart: () => import("monaco-editor/esm/vs/basic-languages/dart/dart.js"),
  dockerfile: () => import("monaco-editor/esm/vs/basic-languages/dockerfile/dockerfile.js"),
  elixir: () => import("monaco-editor/esm/vs/basic-languages/elixir/elixir.js"),
  go: () => import("monaco-editor/esm/vs/basic-languages/go/go.js"),
  graphql: () => import("monaco-editor/esm/vs/basic-languages/graphql/graphql.js"),
  hcl: () => import("monaco-editor/esm/vs/basic-languages/hcl/hcl.js"),
  html: () => import("monaco-editor/esm/vs/basic-languages/html/html.js"),
  java: () => import("monaco-editor/esm/vs/basic-languages/java/java.js"),
  javascript: () => import("monaco-editor/esm/vs/basic-languages/javascript/javascript.js"),
  kotlin: () => import("monaco-editor/esm/vs/basic-languages/kotlin/kotlin.js"),
  less: () => import("monaco-editor/esm/vs/basic-languages/less/less.js"),
  lua: () => import("monaco-editor/esm/vs/basic-languages/lua/lua.js"),
  markdown: () => import("monaco-editor/esm/vs/basic-languages/markdown/markdown.js"),
  "objective-c": () => import("monaco-editor/esm/vs/basic-languages/objective-c/objective-c.js"),
  php: () => import("monaco-editor/esm/vs/basic-languages/php/php.js"),
  protobuf: () => import("monaco-editor/esm/vs/basic-languages/protobuf/protobuf.js"),
  python: () => import("monaco-editor/esm/vs/basic-languages/python/python.js"),
  r: () => import("monaco-editor/esm/vs/basic-languages/r/r.js"),
  ruby: () => import("monaco-editor/esm/vs/basic-languages/ruby/ruby.js"),
  rust: () => import("monaco-editor/esm/vs/basic-languages/rust/rust.js"),
  scala: () => import("monaco-editor/esm/vs/basic-languages/scala/scala.js"),
  scheme: () => import("monaco-editor/esm/vs/basic-languages/scheme/scheme.js"),
  scss: () => import("monaco-editor/esm/vs/basic-languages/scss/scss.js"),
  shell: () => import("monaco-editor/esm/vs/basic-languages/shell/shell.js"),
  sol: () => import("monaco-editor/esm/vs/basic-languages/solidity/solidity.js"),
  sql: () => import("monaco-editor/esm/vs/basic-languages/sql/sql.js"),
  swift: () => import("monaco-editor/esm/vs/basic-languages/swift/swift.js"),
  typescript: () => import("monaco-editor/esm/vs/basic-languages/typescript/typescript.js"),
  xml: () => import("monaco-editor/esm/vs/basic-languages/xml/xml.js"),
  yaml: () => import("monaco-editor/esm/vs/basic-languages/yaml/yaml.js"),
};

const monarchLanguagePromises = new Map<string, Promise<boolean>>();

export function ensureMonacoLanguageTokenizer(languageId: string): Promise<boolean> {
  if (languageId === "json") {
    const existing = monarchLanguagePromises.get(languageId);
    if (existing) return existing;

    const promise = import("monaco-editor/esm/vs/language/json/tokenization.js")
      .then(({ createTokenizationSupport }) => {
        languages.setTokensProvider(languageId, createTokenizationSupport(true));
        return true;
      })
      .catch((error) => {
        monarchLanguagePromises.delete(languageId);
        throw error;
      });
    monarchLanguagePromises.set(languageId, promise);
    return promise;
  }

  const loader = monarchLanguageLoaders[languageId];
  if (!loader) return Promise.resolve(false);

  const existing = monarchLanguagePromises.get(languageId);
  if (existing) return existing;

  const promise = loader()
    .then((module) => {
      languages.setLanguageConfiguration(languageId, module.conf);
      languages.setMonarchTokensProvider(languageId, module.language);
      return true;
    })
    .catch((error) => {
      monarchLanguagePromises.delete(languageId);
      throw error;
    });
  monarchLanguagePromises.set(languageId, promise);
  return promise;
}

function ensureLanguage(id: string, extensions: string[], aliases: string[], filenames?: string[]) {
  if (languages.getLanguages().some((language) => language.id === id)) return;
  languages.register({ id, extensions, aliases, filenames });
}

ensureLanguage("diff", [".diff", ".patch"], ["Diff", "diff", "patch"]);
ensureLanguage("dotenv", [".env"], ["Environment", "dotenv"], [".env"]);
languages.setMonarchTokensProvider("diff", {
  tokenizer: {
    root: [
      [/^@@.*$/, "keyword"],
      [/^diff --git.*$/, "keyword"],
      [/^index\s.*$/, "comment"],
      [/^---.*$/, "comment"],
      [/^\+\+\+.*$/, "comment"],
      [/^\+.*/, "string"],
      [/^-.*/, "regexp"],
    ],
  },
});

ensureLanguage("r", [".r", ".R"], ["R", "r"], [".Rprofile"]);
ensureLanguage("rmarkdown", [".rmd", ".Rmd"], ["R Markdown", "rmd"]);
ensureLanguage("jupyter-notebook", [".ipynb"], ["Jupyter Notebook", "ipynb"]);

ensureLanguage(
  "gitignore",
  [
    ".gitignore",
    ".dockerignore",
    ".ignore",
    ".npmignore",
    ".eslintignore",
    ".prettierignore",
    ".stylelintignore",
    ".vscodeignore",
    ".rgignore",
    ".fdignore",
  ],
  ["Git Ignore", "gitignore", "ignore"],
  [
    ".gitignore",
    ".dockerignore",
    ".ignore",
    ".npmignore",
    ".eslintignore",
    ".prettierignore",
    ".stylelintignore",
    ".vscodeignore",
    ".rgignore",
    ".fdignore",
  ],
);
languages.setMonarchTokensProvider("gitignore", {
  tokenizer: {
    root: [
      [/^\s*#.*$/, "comment"],
      [/^\s*!/, "keyword"],
      [/\\[# !]/, "string.escape"],
      [/[/?*[\]]/, "operator"],
      [/[^/?*[\]\s]+/, "string"],
    ],
  },
});

ensureLanguage(
  "gitattributes",
  [".gitattributes"],
  ["Git Attributes", "gitattributes"],
  [".gitattributes"],
);
languages.setMonarchTokensProvider("gitattributes", {
  tokenizer: {
    root: [
      [/^\s*#.*$/, "comment"],
      [/^\s*\[attr\][^\s]+/, "attribute"],
      [/^\S+/, "string"],
      [/[!-](?=[A-Za-z0-9_.-])/, "operator"],
      [/[A-Za-z0-9_.-]+(?==)/, "key"],
      [/=/, "operator"],
      [/[A-Za-z0-9_.-]+/, "key"],
    ],
  },
});

ensureLanguage("toml", [".toml"], ["TOML", "toml"]);
languages.setMonarchTokensProvider("toml", {
  tokenizer: {
    root: [
      [/^\s*#.*$/, "comment"],
      [/\[[^\]]+\]/, "type"],
      [/^\s*[A-Za-z0-9_.-]+(?=\s*=)/, "key"],
      [/".*?"/, "string"],
      [/'[^']*'/, "string"],
      [/\b(true|false)\b/, "keyword"],
      [/\b\d+(\.\d+)?\b/, "number"],
    ],
  },
});

ensureLanguage("zig", [".zig"], ["Zig", "zig"]);
languages.setMonarchTokensProvider("zig", zigMonarchLanguage);

ensureLanguage("elm", [".elm"], ["Elm", "elm"]);
languages.setMonarchTokensProvider("elm", {
  tokenizer: {
    root: [
      [/--.*$/, "comment"],
      [/\{-/, "comment", "@comment"],
      [/"([^"\\]|\\.)*$/, "string.invalid"],
      [/"/, "string", "@string"],
      [/'([^'\\]|\\.)*'/, "string"],
      [
        /\b(alias|as|case|else|exposing|if|import|in|infix|let|module|of|port|then|type|where)\b/,
        "keyword",
      ],
      [/\b(True|False)\b/, "constant"],
      [/\b[A-Z][\w']*/, "type"],
      [/\b\d+(\.\d+)?\b/, "number"],
    ],
    comment: [
      [/[^{-]+/, "comment"],
      [/\{-/, "comment", "@push"],
      [/-\}/, "comment", "@pop"],
      [/[{-]/, "comment"],
    ],
    string: [
      [/[^\\"]+/, "string"],
      [/\\./, "string.escape"],
      [/"/, "string", "@pop"],
    ],
  },
});

ensureLanguage("elisp", [".el"], ["Emacs Lisp", "elisp"]);
languages.setMonarchTokensProvider("elisp", {
  tokenizer: {
    root: [
      [/;.*/, "comment"],
      [/"([^"\\]|\\.)*$/, "string.invalid"],
      [/"/, "string", "@string"],
      [
        /\b(defun|defmacro|defvar|defcustom|defgroup|defconst|let|let\*|lambda|if|when|unless|cond|pcase|progn|save-excursion|interactive|setq|setq-local|require|provide|use-package)\b/,
        "keyword",
      ],
      [/\b(nil|t)\b/, "constant"],
      [/:[A-Za-z0-9_-]+/, "type"],
      [/\b\d+(\.\d+)?\b/, "number"],
      [/[()'`,#]/, "delimiter"],
    ],
    string: [
      [/[^\\"]+/, "string"],
      [/\\./, "string.escape"],
      [/"/, "string", "@pop"],
    ],
  },
});

ensureLanguage("lockfile", [".lock"], ["Lockfile", "lockfile"]);
languages.setMonarchTokensProvider("lockfile", {
  tokenizer: {
    root: [
      [/^\s*#.*$/, "comment"],
      [/^\s*("[^"]+"|'[^']+'|[^:\s][^:]*)(?=:)/, "key"],
      [/"([^"\\]|\\.)*"/, "string"],
      [/'([^'\\]|\\.)*'/, "string"],
      [/\b(true|false|null)\b/, "constant"],
      [/\b\d+(\.\d+)?\b/, "number"],
      [/[{}[\],:]/, "delimiter"],
    ],
  },
});

ensureLanguage("nix", [".nix"], ["Nix", "nix"]);
languages.setMonarchTokensProvider("nix", {
  tokenizer: {
    root: [
      [/#.*$/, "comment"],
      [/''/, "string", "@indentedString"],
      [/"([^"\\]|\\.)*$/, "string.invalid"],
      [/"/, "string", "@string"],
      [/<[A-Za-z0-9._+:-]+>/, "string"],
      [/\b[A-Za-z][A-Za-z0-9+.-]*:\/\/[^\s;"')\]}]+/, "string"],
      [/(?:\.\.?|~)?\/[A-Za-z0-9._+@%=-][A-Za-z0-9._+@%/=-]*/, "string"],
      [/\b(assert|else|if|in|inherit|let|or|rec|then|with)\b/, "keyword"],
      [/\b(true|false|null)\b/, "constant"],
      [
        /\b(abort|baseNameOf|builtins|derivation|derivationStrict|dirOf|fetchGit|fetchMercurial|fetchTarball|fetchTree|fromTOML|import|isNull|map|placeholder|removeAttrs|scopedImport|throw|toString)\b/,
        "function.builtin",
      ],
      [
        /\b(__currentSystem|__currentTime|__langVersion|__nixPath|__nixVersion|__storeDir)\b/,
        "constant.builtin",
      ],
      [/\b\d+(\.\d+)?\b/, "number"],
      [/[A-Za-z_][\w'-]*(?=\s*=)/, "key"],
      [/[A-Za-z_][\w'-]*(?=\s*:)/, "variable.parameter"],
      [/[A-Za-z_][\w'-]*/, "identifier"],
      [/==|!=|<=|>=|&&|\|\||\/\/|\+\+|->|[=!<>+\-*/?@:]+/, "operator"],
      [/[{}[\]();.,]/, "delimiter"],
    ],
    string: [
      [/\$\{/, "delimiter.bracket"],
      [/[^\\"$]+/, "string"],
      [/\\./, "string.escape"],
      [/"/, "string", "@pop"],
      [/./, "string"],
    ],
    indentedString: [
      [/\$\{/, "delimiter.bracket"],
      [/'''/, "string.escape"],
      [/''/, "string", "@pop"],
      [/./, "string"],
    ],
  },
});

ensureLanguage("ocaml", [".ml", ".mli"], ["OCaml", "ocaml"]);
languages.setMonarchTokensProvider("ocaml", {
  tokenizer: {
    root: [
      [/\(\*/, "comment", "@comment"],
      [/"([^"\\]|\\.)*$/, "string.invalid"],
      [/"/, "string", "@string"],
      [
        /\b(let|in|rec|type|module|open|match|with|function|fun|if|then|else|struct|sig|end)\b/,
        "keyword",
      ],
      [/\b(true|false)\b/, "constant"],
      [/\b\d+(\.\d+)?\b/, "number"],
    ],
    comment: [
      [/[^(*]+/, "comment"],
      [/\*\)/, "comment", "@pop"],
      [/[(*)]/, "comment"],
    ],
    string: [
      [/[^\\"]+/, "string"],
      [/\\./, "string.escape"],
      [/"/, "string", "@pop"],
    ],
  },
});

/// Languages worth loading before the user opens a file. Monarch tokenizers are
/// lazily imported, so the first file of a given language would otherwise render
/// uncolored for a frame or two while its chunk loads.
const PREWARMED_LANGUAGE_IDS = [
  "java",
  "typescript",
  "javascript",
  "python",
  "json",
  "yaml",
  "markdown",
] as const;

let prewarmStarted = false;

/**
 * Loads the tokenizers for commonly opened languages in the background.
 *
 * Safe to call more than once: `ensureMonacoLanguageTokenizer` caches its
 * promises, and this function additionally guards against repeat scheduling.
 * Failures are ignored because the per-file load path reports them already.
 */
export function prewarmCommonLanguageTokenizers(): void {
  if (prewarmStarted) return;
  prewarmStarted = true;

  const schedule =
    typeof requestIdleCallback === "function"
      ? requestIdleCallback
      : (callback: () => void) => setTimeout(callback, 0);

  schedule(() => {
    for (const languageId of PREWARMED_LANGUAGE_IDS) {
      void ensureMonacoLanguageTokenizer(languageId).catch(() => false);
    }
  });
}

// JSON syntax registration does not require starting the JSON language service.
ensureLanguage("json", [".json", ".jsonc"], ["JSON", "json"]);
