#!/usr/bin/env node
// Desktop interface text must come from shared/i18n. Every literal i18n.Shared/SharedFormat
// lookup in desktop/internal must name a key declared for desktop with matching parameters,
// and workbench views must not draw bare literals.
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { basename, join, relative, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { loadContract } from "./generate-i18n.mjs";

const root = fileURLToPath(new URL("../..", import.meta.url));
const violations = [];

// Desktop uses the same generated registry. Each literal lookup must be declared
// for desktop so a missing translation cannot silently reach the UI.
const desktopRoot = join(root, "desktop/internal");
if (existsSync(desktopRoot)) {
  const contract = await loadContract(root);
  const desktopMessages = new Map(contract.messages.filter((message) => message.platforms.includes("desktop")).map((message) => [message.id, message]));
  function goFiles(dir) {
    return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => entry.isDirectory() ? goFiles(join(dir, entry.name)) : entry.name.endsWith(".go") && !entry.name.endsWith("_test.go") && !entry.name.endsWith(".generated.go") ? [join(dir, entry.name)] : []);
  }
  for (const file of goFiles(desktopRoot)) {
    const text = readFileSync(file, "utf8");
    const inCatalog = file.startsWith(`${join(desktopRoot, "i18n")}${sep}`);
    const lookup = inCatalog
      ? /(?:\bi18n\.)?\b(SharedFormat|Shared)\([^,]+,\s*"([^"\n]+)"/g
      : /\bi18n\.(SharedFormat|Shared)\([^,]+,\s*"([^"\n]+)"/g;
    for (const match of text.matchAll(lookup)) {
      const [, method, key] = match;
      const message = desktopMessages.get(key);
      if (!message) violations.push(`${relative(root, file)} (desktop key missing from shared/i18n: ${key})`);
      else if (method === "Shared" && Object.keys(message.parameters ?? {}).length) violations.push(`${relative(root, file)} (desktop key requires SharedFormat: ${key})`);
      else if (method === "SharedFormat") {
        const invocation = text.slice(match.index).match(/^(?:i18n\.)?SharedFormat\(\s*[\w.()]+\s*,\s*"[^"\n]+"\s*,\s*map\[string\]string\s*\{([^}]*)\}\s*\)/s);
        if (!invocation) {
          violations.push(`${relative(root, file)} (desktop SharedFormat requires a literal parameter map: ${key})`);
        } else {
          const supplied = [...invocation[1].matchAll(/"([a-zA-Z][a-zA-Z0-9]*)"\s*:/g)].map((item) => item[1]);
          const declared = Object.keys(message.parameters ?? {});
          const optional = Object.keys(message.optionalParameters ?? {});
          if (new Set(supplied).size !== supplied.length || supplied.some((name) => !declared.includes(name)) || declared.some((name) => !optional.includes(name) && !supplied.includes(name))) {
            violations.push(`${relative(root, file)} (desktop SharedFormat parameters differ from shared/i18n: ${key})`);
          }
        }
      }
    }
    const call = inCatalog
      ? /(?:\bi18n\.)?\b(SharedFormat|Shared)\(\s*[\w.()]+\s*,\s*([^,\s)]+)/g
      : /\bi18n\.(SharedFormat|Shared)\(\s*[\w.()]+\s*,\s*([^,\s)]+)/g;
    for (const match of text.matchAll(call)) {
      if (!match[2].startsWith('"')) violations.push(`${relative(root, file)} (desktop shared lookup requires a literal key)`);
    }
    if (file.startsWith(`${join(desktopRoot, "settingswindow")}${sep}`)) {
      for (const match of text.matchAll(/\bmarketText\(\s*"([^"\n]+)"\s*\)/g)) {
        const message = desktopMessages.get(match[1]);
        if (!message) violations.push(`${relative(root, file)} (desktop key missing from shared/i18n: ${match[1]})`);
        else if (Object.keys(message.parameters ?? {}).length) violations.push(`${relative(root, file)} (desktop key requires SharedFormat: ${match[1]})`);
      }
    }
    if (inCatalog && ["en.go", "zh.go"].includes(basename(file))) {
      if (/^\s*\w+:\s*"(?:\\.|[^"\\])*"\s*,/m.test(text) || /\breturn\s+"(?:\\.|[^"\\])*"/.test(text) || /\bfmt\.Sprintf\(\s*"/.test(text)) {
        violations.push(`${relative(root, file)} (desktop catalog contains handwritten interface text)`);
      }
    }
    const localPath = relative(desktopRoot, file).split(sep);
    if (["workbench", "settingswindow", "logwindow", "editorview", "termview"].includes(localPath[0])) {
      for (const line of text.split("\n")) {
        if (/^\s*\/\//.test(line)) continue;
        const direct = /(?:\bf\.(?:Text|Wrap|Paragraph)|\.(?:Label|Hint|Placeholder|Tooltip|notify))\(\s*"((?:\\.|[^"\\])*)"/g;
        const button = /\bf\.Button\([^,\n]+,\s*"((?:\\.|[^"\\])*)"/g;
        const hit = /\.Hit(?:With)?\([^,\n]+,\s*"((?:\\.|[^"\\])*)"/g;
        const field = /\bf\.(?:Field|FieldBase)\([^,\n]+,[^,\n]+,\s*"((?:\\.|[^"\\])*)"/g;
        const option = /\b(?:Label|Hint|Title|Description|Placeholder):\s*"((?:\\.|[^"\\])*)"/g;
        for (const match of [...line.matchAll(direct), ...line.matchAll(button), ...line.matchAll(hit), ...line.matchAll(field), ...line.matchAll(option)]) {
          if (/\p{L}/u.test(match[1])) violations.push(`${relative(root, file)} (desktop interface text must use shared/i18n)`);
        }
      }
    }
  }
}

if (violations.length > 0) {
  console.error("Localization violations (use i18n.Shared or i18n.SharedFormat with a key defined in shared/i18n):");
  for (const v of violations) console.error(`  ${v}`);
  process.exit(1);
}
console.log("App-language localization check passed.");
