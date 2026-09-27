/**
 * Full Language Extensions
 * These extensions include LSP servers, formatters, linters, and other native components
 * that need to be downloaded as platform-specific packages.
 */

import type {
  ExtensionManifest,
  LanguageContribution,
  LspConfiguration,
  ToolRuntime,
} from "../types/extension-manifest";

function parserInstallation(languageId: string): ExtensionManifest["installation"] {
  return {
    downloadUrl: `/tree-sitter/parsers/${languageId}/parser.wasm`,
    size: 0,
    checksum: "",
    minEditorVersion: "0.2.0",
  };
}

function createLanguageToolExtension(config: {
  id: string;
  name: string;
  displayName: string;
  description: string;
  languages: LanguageContribution[];
  lsp: {
    name: string;
    runtime?: ToolRuntime;
    package?: string;
    packages?: string[];
    downloadUrl?: string;
    command?: string;
    args?: string[];
    env?: Record<string, string>;
    initializationOptions?: Record<string, unknown>;
  };
  formatter?: ExtensionManifest["formatter"];
  linter?: ExtensionManifest["linter"];
  primaryParserLanguageId?: string;
}): ExtensionManifest {
  const fileExtensions = config.languages.flatMap((language) => language.extensions);
  const languageIds = config.languages.map((language) => language.id);
  const lsp: LspConfiguration = {
    name: config.lsp.name,
    runtime: config.lsp.runtime,
    package: config.lsp.package,
    packages: config.lsp.packages,
    downloadUrl: config.lsp.downloadUrl,
    server: { default: config.lsp.command ?? config.lsp.name },
    args: config.lsp.args ?? [],
    env: config.lsp.env,
    initializationOptions: config.lsp.initializationOptions,
    fileExtensions,
    languageIds,
  };

  return {
    id: config.id,
    name: config.name,
    displayName: config.displayName,
    description: config.description,
    version: "1.0.0",
    publisher: "Lithe",
    categories: ["Language"],
    languages: config.languages,
    activationEvents: languageIds.map((languageId) => `onLanguage:${languageId}`),
    lsp,
    formatter: config.formatter,
    linter: config.linter,
    installation: parserInstallation(config.primaryParserLanguageId ?? languageIds[0] ?? "text"),
  };
}

/**
 * Full extension manifests for languages with LSP support
 */
const fullExtensions: ExtensionManifest[] = [
  {
    id: "lithe.r",
    name: "R",
    displayName: "R",
    description:
      "R language support with diagnostics, completions, hover, and symbols via languageserver",
    version: "1.0.0",
    publisher: "Lithe",
    categories: ["Language"],
    languages: [
      {
        id: "r",
        extensions: [".R", ".r"],
        aliases: ["R", "r"],
      },
    ],
    activationEvents: ["onLanguage:r"],
    lsp: {
      name: "r-languageserver",
      runtime: "r",
      package: "languageserver",
      server: { default: "r-languageserver" },
      args: [],
      fileExtensions: [".R", ".r"],
      languageIds: ["r"],
    },
    installation: {
      downloadUrl: "/tree-sitter/parsers/r/parser.wasm",
      size: 1,
      checksum: "",
      minEditorVersion: "0.2.0",
    },
  },
  createLanguageToolExtension({
    id: "lithe.typescript",
    name: "TypeScript",
    displayName: "TypeScript and JavaScript",
    description:
      "TypeScript and JavaScript language support with completions, diagnostics, rename, references, and code actions via typescript-language-server.",
    languages: [
      {
        id: "typescript",
        extensions: [".ts", ".mts", ".cts"],
        aliases: ["TypeScript", "ts"],
      },
      {
        id: "typescriptreact",
        extensions: [".tsx"],
        aliases: ["TSX", "TypeScript React"],
      },
      {
        id: "javascript",
        extensions: [".js", ".mjs", ".cjs"],
        aliases: ["JavaScript", "js"],
      },
      {
        id: "javascriptreact",
        extensions: [".jsx"],
        aliases: ["JSX", "JavaScript React"],
      },
    ],
    lsp: {
      name: "typescript-language-server",
      runtime: "bun",
      package: "typescript-language-server",
      packages: ["typescript"],
      args: ["--stdio"],
    },
    primaryParserLanguageId: "typescript",
  }),
  createLanguageToolExtension({
    id: "lithe.python",
    name: "Python",
    displayName: "Python",
    description:
      "Python language support with completions, diagnostics, rename, references, and code actions via Pyright.",
    languages: [
      {
        id: "python",
        extensions: [".py", ".ipy", ".pyi"],
        aliases: ["Python", "py"],
      },
    ],
    lsp: {
      name: "pyright",
      runtime: "bun",
      package: "pyright",
      args: ["--stdio"],
    },
  }),
  createLanguageToolExtension({
    id: "lithe.rust",
    name: "Rust",
    displayName: "Rust",
    description:
      "Rust language support with completions, diagnostics, rename, references, semantic tokens, and code actions via rust-analyzer.",
    languages: [
      {
        id: "rust",
        extensions: [".rs"],
        aliases: ["Rust", "rs"],
      },
    ],
    lsp: {
      name: "rust-analyzer",
      runtime: "system",
    },
  }),
  createLanguageToolExtension({
    id: "lithe.go",
    name: "Go",
    displayName: "Go",
    description:
      "Go language support with completions, diagnostics, rename, references, and code actions via gopls.",
    languages: [
      {
        id: "go",
        extensions: [".go"],
        aliases: ["Go", "golang"],
        filenames: ["go.mod", "go.sum", "go.work"],
      },
    ],
    lsp: {
      name: "gopls",
      runtime: "go",
      package: "golang.org/x/tools/gopls",
    },
  }),
  createLanguageToolExtension({
    id: "lithe.markdown",
    name: "Markdown",
    displayName: "Markdown",
    description:
      "Markdown language support with symbols, references, and diagnostics via Marksman.",
    languages: [
      {
        id: "markdown",
        extensions: [".md", ".mdx", ".markdown"],
        aliases: ["Markdown", "md"],
      },
    ],
    lsp: {
      name: "marksman",
      runtime: "binary",
      args: ["server"],
    },
  }),
  createLanguageToolExtension({
    id: "lithe.lua",
    name: "Lua",
    displayName: "Lua",
    description:
      "Lua language support with completions, diagnostics, rename, references, and semantic tokens via LuaLS.",
    languages: [
      {
        id: "lua",
        extensions: [".lua"],
        aliases: ["Lua"],
      },
    ],
    lsp: {
      name: "lua-language-server",
      runtime: "binary",
    },
  }),
  createLanguageToolExtension({
    id: "lithe.zig",
    name: "Zig",
    displayName: "Zig",
    description:
      "Zig language support with completions, diagnostics, rename, references, and code actions via ZLS.",
    languages: [
      {
        id: "zig",
        extensions: [".zig"],
        aliases: ["Zig"],
      },
    ],
    lsp: {
      name: "zls",
      runtime: "binary",
    },
  }),
  createLanguageToolExtension({
    id: "lithe.cpp",
    name: "C/C++",
    displayName: "C/C++",
    description:
      "C and C++ language support with completions, diagnostics, rename, references, and code actions via clangd.",
    languages: [
      {
        id: "c",
        extensions: [".c", ".h"],
        aliases: ["C"],
      },
      {
        id: "cpp",
        extensions: [".cpp", ".cc", ".cxx", ".hpp", ".hh", ".hxx"],
        aliases: ["C++", "cpp"],
      },
    ],
    lsp: {
      name: "clangd",
      runtime: "binary",
    },
    primaryParserLanguageId: "cpp",
  }),
  createLanguageToolExtension({
    id: "lithe.json",
    name: "JSON",
    displayName: "JSON",
    description:
      "JSON language support with schema-aware completions and diagnostics via vscode-json-language-server.",
    languages: [
      {
        id: "json",
        extensions: [".json", ".jsonc"],
        aliases: ["JSON", "jsonc"],
        filenames: ["tsconfig.json", "jsconfig.json"],
      },
    ],
    lsp: {
      name: "vscode-json-language-server",
      runtime: "bun",
      package: "vscode-langservers-extracted",
      args: ["--stdio"],
    },
  }),
  createLanguageToolExtension({
    id: "lithe.web",
    name: "HTML",
    displayName: "HTML",
    description:
      "HTML language support with completions, diagnostics, hover, and document symbols via vscode-html-language-server.",
    languages: [
      {
        id: "html",
        extensions: [".html", ".htm"],
        aliases: ["HTML"],
      },
    ],
    lsp: {
      name: "vscode-html-language-server",
      runtime: "bun",
      package: "vscode-langservers-extracted",
      args: ["--stdio"],
    },
    primaryParserLanguageId: "html",
  }),
  createLanguageToolExtension({
    id: "lithe.css",
    name: "CSS",
    displayName: "CSS",
    description:
      "CSS, SCSS, Less, and Sass language support with completions and diagnostics via vscode-css-language-server.",
    languages: [
      {
        id: "css",
        extensions: [".css"],
        aliases: ["CSS"],
      },
      {
        id: "scss",
        extensions: [".scss"],
        aliases: ["SCSS"],
      },
      {
        id: "less",
        extensions: [".less"],
        aliases: ["Less"],
      },
      {
        id: "sass",
        extensions: [".sass"],
        aliases: ["Sass"],
      },
    ],
    lsp: {
      name: "vscode-css-language-server",
      runtime: "bun",
      package: "vscode-langservers-extracted",
      args: ["--stdio"],
    },
    primaryParserLanguageId: "css",
  }),
  createLanguageToolExtension({
    id: "lithe.yaml",
    name: "YAML",
    displayName: "YAML",
    description:
      "YAML language support with completions, diagnostics, hover, and schema integration via yaml-language-server.",
    languages: [
      {
        id: "yaml",
        extensions: [".yaml", ".yml"],
        aliases: ["YAML", "YML"],
      },
    ],
    lsp: {
      name: "yaml-language-server",
      runtime: "bun",
      package: "yaml-language-server",
      args: ["--stdio"],
    },
  }),
];

/**
 * Get all full extension manifests
 */
export function getFullExtensions(): ExtensionManifest[] {
  return fullExtensions;
}
