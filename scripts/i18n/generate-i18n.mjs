#!/usr/bin/env node
// Build-time only. Note: .agents/notes/implemented/architecture/2026-10-23-shared-i18n-generation.md
import { readFile, writeFile, mkdir, mkdtemp, readdir, access, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { execFile } from "node:child_process";
import { promisify } from "node:util";

export const ROOT = path.dirname(path.dirname(path.dirname(fileURLToPath(import.meta.url))));
const PLATFORMS = ["macos", "windows", "desktop"];
// gofmt formats the desktop catalog (about 450 KB) in well under a second.
const GOFMT_TIMEOUT_MS = 10_000;
const GOFMT_MAX_OUTPUT_BYTES = 64 * 1024 * 1024;
const execFileAsync = promisify(execFile);
const fail = (message) => {
  throw new Error(`i18n: ${message}`);
};

// gofmt reads the source from a file in a private temporary directory, not from stdin. Fed
// through stdin by Node, gofmt on macOS occasionally never receives end of input and waits
// forever, and a synchronous spawn also stops the test runner from enforcing its timeout.
// The directory is outside the repository, so --check still leaves repository files untouched.
async function gofmt(source) {
  const directory = await mkdtemp(path.join(os.tmpdir(), "lithe-i18n-gofmt-"));
  try {
    const file = path.join(directory, "shared.generated.go");
    await writeFile(file, source);
    const { stdout } = await execFileAsync("gofmt", [file], {
      encoding: "utf8",
      timeout: GOFMT_TIMEOUT_MS,
      maxBuffer: GOFMT_MAX_OUTPUT_BYTES,
      windowsHide: true,
    });
    return stdout;
  } catch (error) {
    const reason = error.killed
      ? `no result within ${GOFMT_TIMEOUT_MS} ms`
      : error.stderr?.trim() || error.message;
    fail(`gofmt failed: ${reason}`);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
}
const record = (value) => value !== null && typeof value === "object" && !Array.isArray(value);
const own = (object, key) => Object.hasOwn(object, key);
function fields(value, allowed, label) {
  if (!record(value)) fail(`${label} must be an object`);
  for (const key of Object.keys(value))
    if (!allowed.includes(key)) fail(`${label}: unknown field ${key}`);
}
function nonempty(value, label) {
  if (
    typeof value !== "string" ||
    !value.trim() ||
    /[\u0000-\u0008\u000b\u000c\u000e-\u001f]/u.test(value)
  )
    fail(`${label} must be nonempty text`);
}
function unique(values, label) {
  if (new Set(values).size !== values.length) fail(`${label} must be unique`);
}

// JSON.parse silently keeps the last duplicate. Reject duplicates before a
// translator can lose a value, including escaped spellings of the same key.
export function parseJSON(source, label) {
  let parsed;
  try {
    parsed = JSON.parse(source);
  } catch (error) {
    fail(`${label}: ${error.message}`);
  }
  const tokens =
    source.match(
      /"(?:\\.|[^"\\])*"|[{}\[\]:,]|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?|true|false|null/g,
    ) ?? [];
  const stack = [];
  tokens.forEach((token, index) => {
    if (token === "{") stack.push(new Set());
    else if (token === "[") stack.push(null);
    else if (token === "}" || token === "]") stack.pop();
    else if (token.startsWith('"') && tokens[index + 1] === ":") {
      const key = JSON.parse(token);
      if (stack.at(-1).has(key)) fail(`${label}: duplicate JSON key ${key}`);
      stack.at(-1).add(key);
    }
  });
  return parsed;
}
async function json(root, relative) {
  return parseJSON(await readFile(path.join(root, relative), "utf8"), relative);
}

async function loadFeatures(root, localeIDs) {
  let entries;
  try {
    entries = await readdir(path.join(root, "shared/i18n/features"), { withFileTypes: true });
  } catch (error) {
    // Older source trees keep every declaration in messages.json.
    if (error.code === "ENOENT") return [];
    throw error;
  }
  const features = [];
  for (const entry of entries.sort((a, b) => a.name < b.name ? -1 : a.name > b.name ? 1 : 0)) {
    const relative = `shared/i18n/features/${entry.name}`;
    if (!entry.isFile() || !entry.name.endsWith(".json")) fail(`${relative}: expected a JSON file`);
    const feature = await json(root, relative);
    fields(feature, ["schemaVersion", "messages", "locales"], relative);
    if (feature.schemaVersion !== 1 || !Array.isArray(feature.messages) || !feature.messages.length)
      fail(`${relative}: unsupported feature catalog`);
    fields(feature.locales, localeIDs, `${relative} locales`);
    const keys = feature.messages.map((message) => message?.id);
    for (const [locale, translations] of Object.entries(feature.locales))
      fields(translations, keys, `${relative}/${locale}`);
    features.push(feature);
  }
  return features;
}

function parameters(text, message, label) {
  if (!(message.allowEmptyTranslation && text === "")) nonempty(text, label);
  const names = [...text.matchAll(/\{([a-zA-Z][a-zA-Z0-9]*)\}/g)].map((match) => match[1]);
  if (!message.literalBraces && /[{}]/.test(text.replace(/\{[a-zA-Z][a-zA-Z0-9]*\}/g, "")))
    fail(`${label}: malformed placeholder`);
  const expected = Object.keys(message.parameters ?? {});
  const optional = Object.keys(message.optionalParameters ?? {});
  if (names.some((name) => !expected.includes(name)) && !message.literalBraces)
    fail(`${label}: unknown placeholder`);
  if (expected.some((name) => !optional.includes(name) && !names.includes(name)))
    fail(`${label}: placeholder names differ from ${expected.join(", ")}`);
}

export async function loadContract(root = ROOT) {
  const manifest = await json(root, "shared/i18n/manifest.json");
  fields(manifest, ["schemaVersion", "defaultLocale", "platformDefaults", "locales"], "manifest");
  if (manifest.schemaVersion !== 1 || !Array.isArray(manifest.locales) || !manifest.locales.length)
    fail("unsupported manifest");
  fields(manifest.platformDefaults, PLATFORMS, "platformDefaults");
  for (const locale of manifest.locales) {
    fields(locale, ["id", "title", "macos", "swiftCase", "fallback", "coverage"], "locale");
    if (typeof locale.id !== "string" || !/^[a-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$/.test(locale.id))
      fail("invalid locale id");
    if (
      typeof locale.macos !== "string" ||
      !/^[a-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$/.test(locale.macos)
    )
      fail(`invalid macOS locale: ${locale.id}`);
    if (
      typeof locale.swiftCase !== "string" ||
      !/^[a-z][a-zA-Z0-9]*$/.test(locale.swiftCase) ||
      [
        "default",
        "case",
        "self",
        "enum",
        "var",
        "let",
        "switch",
        "class",
        "struct",
        "return",
        "static",
        "import",
        "protocol",
        "as", "associatedtype", "break", "catch", "continue", "defer", "deinit", "do",
        "else", "extension", "fallthrough", "false", "fileprivate", "for", "func",
        "guard", "if", "in", "init", "inout", "internal", "is", "nil", "open",
        "operator", "precedencegroup", "private", "public", "repeat", "rethrows", "subscript", "super",
        "throw", "throws", "true", "try", "typealias", "where", "while",
        // These names are emitted by AppLanguage or its synthesized conformances.
        "allCases", "rawValue", "defaultLanguage", "id", "locale", "title",
        "localizedFormat", "localizedString",
      ].includes(locale.swiftCase)
    )
      fail(`invalid Swift case: ${locale.id}`);
    nonempty(locale.title, `${locale.id} title`);
    if (!["complete", "fallback"].includes(locale.coverage)) fail(`invalid coverage: ${locale.id}`);
  }
  for (const field of ["id", "macos", "swiftCase"])
    unique(
      manifest.locales.map((locale) => locale[field].toLowerCase()),
      `locale ${field}`,
    );
  const locales = new Map(manifest.locales.map((locale) => [locale.id, locale]));
  if (!locales.has(manifest.defaultLocale)) fail("unknown default locale");
  const defaultLocale = locales.get(manifest.defaultLocale);
  if (defaultLocale.fallback !== null || defaultLocale.coverage !== "complete")
    fail("default locale must be complete and have null fallback");
  for (const platform of PLATFORMS)
    if (!locales.has(manifest.platformDefaults[platform])) fail(`unknown ${platform} default`);
  for (const locale of manifest.locales) {
    const visited = new Set();
    let current = locale;
    while (current.id !== manifest.defaultLocale) {
      if (visited.has(current.id)) fail(`fallback cycle: ${locale.id}`);
      visited.add(current.id);
      current = locales.get(current.fallback);
      if (!current) fail(`fallback must reach default locale: ${locale.id}`);
    }
  }
  const registry = await json(root, "shared/i18n/messages.json");
  fields(registry, ["schemaVersion", "messages"], "messages");
  if (
    registry.schemaVersion !== 1 ||
    !Array.isArray(registry.messages) ||
    !registry.messages.length
  )
    fail("unsupported messages registry");
  const features = await loadFeatures(root, [...locales.keys()]);
  for (const feature of features) registry.messages.push(...feature.messages);
  const aliases = new Set();
  for (const message of registry.messages) {
    fields(
      message,
      [
        "id",
        "description",
        "platforms",
        "parameters",
        "macos",
        "windows",
        "optionalParameters",
        "literalBraces",
        "allowEmptyTranslation",
      ],
      "message",
    );
    if (
      typeof message.id !== "string" ||
      !/^[a-z][a-zA-Z0-9]*(?:\.[a-zA-Z][a-zA-Z0-9]*)+$/.test(message.id)
    )
      fail("invalid semantic key");
    nonempty(message.description, `${message.id} description`);
    if (
      !Array.isArray(message.platforms) ||
      !message.platforms.length ||
      message.platforms.some((platform) => !PLATFORMS.includes(platform))
    )
      fail(`${message.id}: invalid platform scope`);
    unique(message.platforms, `${message.id} platforms`);
    if (message.parameters !== undefined) {
      if (!record(message.parameters)) fail(`${message.id}: invalid parameters`);
      for (const [name, type] of Object.entries(message.parameters))
        if (
          !/^[a-zA-Z][a-zA-Z0-9]*$/.test(name) ||
          !["string", "integer", "unsignedInteger"].includes(type)
        )
          fail(`${message.id}: invalid parameter ${name}`);
    }
    if (message.allowEmptyTranslation !== undefined && message.allowEmptyTranslation !== true)
      fail(`${message.id}: allowEmptyTranslation must be true`);
    if (message.literalBraces !== undefined && message.literalBraces !== true)
      fail(`${message.id}: literalBraces must be true`);
    if (message.optionalParameters !== undefined) {
      if (!record(message.optionalParameters)) fail(`${message.id}: invalid optional parameters`);
      for (const [name, reason] of Object.entries(message.optionalParameters)) {
        if (!own(message.parameters ?? {}, name))
          fail(`${message.id}: undeclared optional parameter`);
        nonempty(reason, `${message.id}/${name} omission reason`);
      }
    }
    if (message.windows !== undefined) {
      fields(message.windows, ["key"], `${message.id} windows`);
      if (!message.platforms.includes("windows"))
        fail(`${message.id}: Windows alias outside scope`);
      nonempty(message.windows.key, `${message.id} Windows key`);
    }
    if (message.macos !== undefined) {
      if (!message.platforms.includes("macos")) fail(`${message.id}: macOS alias outside scope`);
      fields(message.macos, ["key", "arguments", "formats"], `${message.id} macos`);
      nonempty(message.macos.key, `${message.id} macOS key`);
      if (aliases.has(message.macos.key)) fail(`duplicate macOS alias: ${message.macos.key}`);
      aliases.add(message.macos.key);
      if (!Array.isArray(message.macos.arguments))
        fail(`${message.id}: alias needs argument order`);
      const argumentNames = message.macos.arguments;
      unique(argumentNames, `${message.id} alias arguments`);
      if (
        JSON.stringify([...argumentNames].sort()) !==
        JSON.stringify(Object.keys(message.parameters ?? {}).sort())
      )
        fail(`${message.id}: alias arguments differ`);
      const formats = message.macos.formats ?? {};
      if (!record(formats) || Object.keys(formats).some((name) => !argumentNames.includes(name)))
        fail(`${message.id}: invalid native formats`);
      for (const name of argumentNames) {
        const format = formats[name] ?? defaultFormat(message.parameters[name]);
        const type = { "@": "string", d: "integer", lld: "integer", llu: "unsignedInteger" }[
          format
        ];
        if (type !== message.parameters[name]) fail(`${message.id}: native format type differs`);
      }
      const directives = [
        ...message.macos.key.matchAll(/%%|%(?:([1-9]\d*)\$)?(lld|llu|d|@)/g),
      ].filter((match) => match[0] !== "%%");
      const positions = directives.map((match, index) => Number(match[1] ?? index + 1) - 1);
      const positioned = directives.filter((match) => match[1] !== undefined).length;
      if (
        /%[a-zA-Z]/.test(message.macos.key.replace(/%%|%(?:[1-9]\d*\$)?(?:lld|llu|d|@)/g, "")) ||
        directives.length !== argumentNames.length ||
        (positioned !== 0 && positioned !== directives.length) ||
        new Set(positions).size !== positions.length ||
        positions.some((position) => !Number.isSafeInteger(position) || position < 0 || position >= argumentNames.length) ||
        directives.some(
          (match, index) =>
            match[2] !==
            (formats[argumentNames[positions[index]]] ??
              defaultFormat(message.parameters[argumentNames[positions[index]]])),
        )
      )
        fail(`${message.id}: alias format differs from parameter types`);
    }
  }
  unique(
    registry.messages.map((message) => message.id),
    "semantic keys",
  );
  if (registry.messages.some((message) => aliases.has(message.id)))
    fail("semantic key collides with macOS alias");
  const messages = [...registry.messages].sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
  unique(
    messages
      .filter((message) => message.platforms.includes("windows"))
      .map((message) => message.windows?.key ?? message.id),
    "Windows keys",
  );
  const byID = new Map(messages.map((message) => [message.id, message]));
  const catalogs = new Map();
  const localeFiles = (await readdir(path.join(root, "shared/i18n/locales"))).sort();
  if (
    JSON.stringify(localeFiles) !==
    JSON.stringify([...locales.keys()].map((id) => `${id}.json`).sort())
  )
    fail("locale files differ from manifest");
  for (const locale of manifest.locales) {
    const catalog = await json(root, `shared/i18n/locales/${locale.id}.json`);
    fields(catalog, ["messages", "overrides"], locale.id);
    if (!record(catalog.messages)) fail(`${locale.id}: missing messages`);
    for (const feature of features) {
      for (const [key, text] of Object.entries(feature.locales[locale.id] ?? {})) {
        if (own(catalog.messages, key)) fail(`${locale.id}: duplicate translation ${key}`);
        catalog.messages[key] = text;
      }
    }
    for (const [key, text] of Object.entries(catalog.messages)) {
      if (!byID.has(key)) fail(`${locale.id}: unknown key ${key}`);
      parameters(text, byID.get(key), `${locale.id}/${key}`);
    }
    if (
      locale.coverage === "complete" &&
      messages.some((message) => !own(catalog.messages, message.id))
    )
      fail(`${locale.id}: incomplete translation coverage`);
    fields(catalog.overrides ?? {}, PLATFORMS, `${locale.id} overrides`);
    for (const [platform, overrides] of Object.entries(catalog.overrides ?? {})) {
      if (!record(overrides)) fail(`${locale.id}/${platform}: invalid overrides`);
      for (const [key, override] of Object.entries(overrides)) {
        const message = byID.get(key);
        if (!message || !message.platforms.includes(platform))
          fail(`${locale.id}/${platform}: override outside scope: ${key}`);
        fields(override, ["value", "reason", "nativeFormat"], `${locale.id}/${platform}/${key}`);
        nonempty(override.reason, `${key} override reason`);
        if (
          override.nativeFormat !== undefined &&
          (platform !== "macos" || override.nativeFormat !== "positional")
        )
          fail(`${key}: invalid native format policy`);
        parameters(override.value, message, `${locale.id}/${platform}/${key}`);
      }
    }
    catalogs.set(locale.id, catalog);
  }
  return { manifest, locales, messages, catalogs };
}

export function resolveMessage(contract, localeID, platform, key) {
  const catalog = contract.catalogs.get(localeID);
  const override = catalog.overrides?.[platform]?.[key];
  if (override) return override.value;
  if (own(catalog.messages, key)) return catalog.messages[key];
  return resolveMessage(contract, contract.locales.get(localeID).fallback, platform, key);
}

function defaultFormat(type) {
  return type === "integer" ? "lld" : type === "unsignedInteger" ? "llu" : "@";
}

export async function planGeneration(root = ROOT) {
  const contract = await loadContract(root);
  const { manifest, messages } = contract;
  const hasDesktop = await access(path.join(root, "desktop/internal/i18n")).then(() => true, (error) => { if (error.code === "ENOENT") return false; throw error; });
  const outputs = new Map();
  if (hasDesktop) {
    const desktopMessages = messages.filter((message) => message.platforms.includes("desktop"));
    const mappings = manifest.locales.map((locale) => {
      const entries = desktopMessages.map((message) => `\t\t${JSON.stringify(message.id)}: ${JSON.stringify(resolveMessage(contract, locale.id, "desktop", message.id))},`).join("\n");
      return `\t${JSON.stringify(locale.id)}: {\n${entries}\n\t},`;
    }).join("\n");
    const source = `// Code generated by scripts/i18n/generate-i18n.mjs; DO NOT EDIT.\npackage i18n\n\nvar sharedCatalogs = map[string]map[string]string{\n${mappings}\n}\n`;
    outputs.set("desktop/internal/i18n/shared.generated.go", await gofmt(source));
  }
  return { outputs, contract };
}

export async function generate(root = ROOT, check = false) {
  const { outputs, contract } = await planGeneration(root);
  const stale = [];
  // Finish all validation before the first write. --check is strictly read-only.
  for (const [relative, expected] of outputs) {
    let actual;
    try {
      actual = await readFile(path.join(root, relative), "utf8");
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
    }
    if (actual === expected) continue;
    stale.push(relative);
    if (!check) {
      await mkdir(path.dirname(path.join(root, relative)), { recursive: true });
      await writeFile(path.join(root, relative), expected);
    }
  }
  if (check && stale.length)
    fail(`generated files are stale; run node scripts/i18n/generate-i18n.mjs:\n${stale.join("\n")}`);
  return contract;
}

async function main() {
  const args = process.argv.slice(2);
  if (args.length > 1 || args.some((arg) => !["--check", "--coverage"].includes(arg)))
    fail("usage: node scripts/i18n/generate-i18n.mjs [--check|--coverage]");
  const contract =
    args[0] === "--coverage" ? await loadContract() : await generate(ROOT, args[0] === "--check");
  for (const locale of contract.manifest.locales)
    console.log(
      `${locale.id}: ${Object.keys(contract.catalogs.get(locale.id).messages).length}/${contract.messages.length} shared translations (${locale.coverage})`,
    );
}
if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href)
  main().catch((error) => {
    console.error(error.message);
    process.exitCode = 1;
  });
