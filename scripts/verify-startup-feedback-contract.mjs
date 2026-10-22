#!/usr/bin/env node
// Verifies the shared startup feedback contract.
//
// The contract owns the phase vocabulary, the outcome vocabulary, the timing
// thresholds, and the wording both products display. This gate fails when the
// shared fixture drifts, when a product declares different phases, or when the
// two products no longer show the same wording.

import { readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(fileURLToPath(new URL("..", import.meta.url)));
const failures = [];

const schemaPath = join(root, "shared/contracts/startup-feedback-v1.schema.json");
const fixturePath = join(root, "shared/fixtures/settings/startup-feedback-v1.json");
const windowsStagePath = join(
  root,
  "windows/tauri/src/features/bootstrap/startup-animation/startup-stages.ts",
);
const macosStagePath = join(
  root,
  "macos/Sources/Lithe/Application/Lifecycle/StartupFeedback/StartupStage.swift",
);
const macosTimingPath = join(
  root,
  "macos/Sources/Lithe/Application/Lifecycle/StartupFeedback/StartupFeedbackTiming.swift",
);
const windowsLocalePath = join(root, "windows/tauri/src/i18n/locale.ts");
const macosEnglishPath = join(root, "macos/Resources/en.lproj/Localizable.strings");
const macosChinesePath = join(root, "macos/Resources/zh-Hans.lproj/Localizable.strings");
const macosSettingsPath = join(root, "macos/Sources/Lithe/Models/Settings/AppSettings.swift");
const windowsSettingsTypePath = join(
  root,
  "windows/tauri/src/features/settings/types/settings.types.ts",
);
const windowsSettingsDefaultPath = join(
  root,
  "windows/tauri/src/features/settings/config/default-settings.ts",
);

function readJson(path) {
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch (error) {
    failures.push(`${path} is not valid JSON: ${error.message}`);
    return null;
  }
}

function readText(path) {
  try {
    return readFileSync(path, "utf8");
  } catch {
    failures.push(`${path} is missing`);
    return null;
  }
}

function typeOf(value) {
  if (value === null) return "null";
  if (Array.isArray(value)) return "array";
  if (Number.isInteger(value)) return "integer";
  if (typeof value === "number") return "number";
  return typeof value;
}

function resolveRef(ref, schema) {
  if (!ref.startsWith("#/")) {
    failures.push(`unsupported schema reference ${ref}`);
    return null;
  }
  let node = schema;
  for (const part of ref.slice(2).split("/")) {
    node = node?.[part];
  }
  return node;
}

// A validator for the JSON Schema subset used by the shared contracts. It
// covers exactly the keywords the startup contract relies on so a schema change
// fails loudly instead of being silently ignored.
function validate(schema, value, path) {
  if (!schema) return;
  if (schema.$ref) {
    const resolved = resolveRef(schema.$ref, schemaRoot);
    if (resolved) validate(resolved, value, path);
    return;
  }
  if ("const" in schema && JSON.stringify(value) !== JSON.stringify(schema.const)) {
    failures.push(`${path} must equal ${JSON.stringify(schema.const)}`);
    return;
  }
  if (schema.enum && !schema.enum.some((entry) => JSON.stringify(entry) === JSON.stringify(value))) {
    failures.push(`${path} must be one of ${schema.enum.join(", ")}`);
    return;
  }
  if (schema.type) {
    const expected = Array.isArray(schema.type) ? schema.type : [schema.type];
    const actual = typeOf(value);
    if (!expected.includes(actual)) {
      failures.push(`${path} must be ${expected.join(" or ")} but is ${actual}`);
      return;
    }
  }
  if (typeof value === "string") {
    if (schema.minLength !== undefined && value.length < schema.minLength) {
      failures.push(`${path} must not be empty`);
    }
    if (schema.pattern && !new RegExp(schema.pattern).test(value)) {
      failures.push(`${path} must match ${schema.pattern}`);
    }
  }
  if (typeof value === "number") {
    if (schema.minimum !== undefined && value < schema.minimum) {
      failures.push(`${path} must be at least ${schema.minimum}`);
    }
    if (schema.maximum !== undefined && value > schema.maximum) {
      failures.push(`${path} must be at most ${schema.maximum}`);
    }
  }
  if (Array.isArray(value)) {
    if (schema.minItems !== undefined && value.length < schema.minItems) {
      failures.push(`${path} must contain at least ${schema.minItems} entries`);
    }
    if (schema.maxItems !== undefined && value.length > schema.maxItems) {
      failures.push(`${path} must contain at most ${schema.maxItems} entries`);
    }
    if (schema.uniqueItems) {
      const unique = new Set(value.map((entry) => JSON.stringify(entry)));
      if (unique.size !== value.length) failures.push(`${path} must not contain duplicates`);
    }
    if (schema.items) {
      value.forEach((entry, index) => validate(schema.items, entry, `${path}[${index}]`));
    }
  }
  if (value && typeof value === "object" && !Array.isArray(value)) {
    for (const key of schema.required ?? []) {
      if (!(key in value)) failures.push(`${path}.${key} is required`);
    }
    for (const [key, entry] of Object.entries(value)) {
      const property = schema.properties?.[key];
      if (property) {
        validate(property, entry, `${path}.${key}`);
      } else if (schema.additionalProperties === false) {
        failures.push(`${path}.${key} is not allowed`);
      }
    }
  }
}

const schemaRoot = readJson(schemaPath);
const fixture = readJson(fixturePath);
if (schemaRoot && fixture) {
  validate(schemaRoot, fixture, "startupFeedback");
  if (!String(schemaRoot.$id ?? "").endsWith("/startup-feedback-v1.schema.json")) {
    failures.push("startup feedback schema ID must end with /startup-feedback-v1.schema.json");
  }
}

if (fixture) {
  const stages = fixture.stages ?? [];
  const orders = stages.map((stage) => stage.order);
  if (orders.join(",") !== stages.map((_, index) => index + 1).join(",")) {
    failures.push("startup feedback phases must declare a contiguous order starting at 1");
  }
  const stageIds = stages.map((stage) => stage.id);
  if (new Set(stageIds).size !== stageIds.length) {
    failures.push("startup feedback phase ids must be unique");
  }
  const outcomes = fixture.outcomes ?? [];
  if (outcomes.join(",") !== "idle,loading,ready,failed") {
    failures.push('startup feedback outcomes must be exactly "idle,loading,ready,failed"');
  }
  const labelKeys = [];
  for (const stage of stages) labelKeys.push(stage.labelKey);
  for (const message of Object.values(fixture.messages ?? {})) labelKeys.push(message.labelKey);
  if (new Set(labelKeys).size !== labelKeys.length) {
    failures.push("startup feedback label keys must be unique");
  }
  for (const stage of stages) {
    if (stage.labels.en === stage.labels.zhHans) {
      failures.push(`phase ${stage.id} must distinguish the English and Chinese wording`);
    }
    if (!Number.isInteger(stage.progress) || stage.progress < 0 || stage.progress > 100) {
      failures.push(`phase ${stage.id} must declare a progress percentage between 0 and 100`);
    }
  }
  const progressValues = stages.map((stage) => stage.progress);
  for (let index = 1; index < progressValues.length; index += 1) {
    if (!(progressValues[index] > progressValues[index - 1])) {
      failures.push("startup feedback phases must report a strictly increasing progress");
    }
  }

  const windowsStages = readText(windowsStagePath);
  if (windowsStages) {
    const declaredStages = parseWindowsStageLines(windowsStages);
    const declaredIds = declaredStages.map((entry) => entry.id);
    if (declaredIds.join(",") !== stageIds.join(",")) {
      failures.push(
        `Windows startup phases differ from the contract: ${declaredIds.join(", ") || "(none)"}`,
      );
    }
    for (const stage of stages) {
      const declared = declaredStages.find((entry) => entry.id === stage.id);
      if (!declared) {
        failures.push(`Windows startup phase ${stage.id} is not declared`);
        continue;
      }
      if (declared.labelKey !== stage.labelKey) {
        failures.push(`Windows startup label key for phase ${stage.id} differs from the contract`);
      }
      if (declared.progress !== stage.progress) {
        failures.push(`Windows startup progress for phase ${stage.id} differs from the contract`);
      }
      if (declared.en !== stage.labels.en || declared.zhHans !== stage.labels.zhHans) {
        failures.push(`Windows startup wording for phase ${stage.id} differs from the contract`);
      }
    }
    const minimum = /STARTUP_MINIMUM_VISIBLE_DURATION_MS\s*=\s*(\d+)/.exec(windowsStages);
    const fade = /STARTUP_FADE_OUT_DURATION_MS\s*=\s*(\d+)/.exec(windowsStages);
    if (!minimum || Number(minimum[1]) !== fixture.minimumVisibleDurationMs) {
      failures.push("Windows startup skip threshold differs from the contract");
    }
    if (!fade || Number(fade[1]) !== fixture.fadeOutDurationMs) {
      failures.push("Windows startup fade-out duration differs from the contract");
    }
  }

  const macosStages = readText(macosStagePath);
  if (macosStages) {
    const declaredIds = [...macosStages.matchAll(/\bcase\s+[A-Za-z]+\s*=\s*"([^"]+)"/g)].map(
      (match) => match[1],
    );
    if (declaredIds.join(",") !== stageIds.join(",")) {
      failures.push(
        `macOS startup phases differ from the contract: ${declaredIds.join(", ") || "(none)"}`,
      );
    }
    const declaredProgress = [
      ...macosStages.matchAll(/case\s+\.([A-Za-z]+):\s*return\s+(\d+)/g),
    ].map((match) => ({ id: match[1], progress: Number(match[2]) }));
    for (const stage of stages) {
      const declared = declaredProgress.find((entry) => entry.id === stage.id);
      if (!declared) {
        failures.push(`macOS startup phase ${stage.id} does not declare the contract progress`);
        continue;
      }
      if (declared.progress !== stage.progress) {
        failures.push(`macOS startup progress for phase ${stage.id} differs from the contract`);
      }
    }
  }

  const macosTiming = readText(macosTimingPath);
  if (macosTiming) {
    const minimum = /minimumVisibleDuration:\s*Duration\s*=\s*\.milliseconds\((\d+)\)/.exec(macosTiming);
    const fade = /fadeOutDuration:\s*Duration\s*=\s*\.milliseconds\((\d+)\)/.exec(macosTiming);
    if (!minimum || Number(minimum[1]) !== fixture.minimumVisibleDurationMs) {
      failures.push("macOS startup skip threshold differs from the contract");
    }
    if (!fade || Number(fade[1]) !== fixture.fadeOutDurationMs) {
      failures.push("macOS startup fade-out duration differs from the contract");
    }
  }

  const windowsLocale = readText(windowsLocalePath);
  if (windowsLocale) {
    const english = readLocaleSection(windowsLocale, "en-US");
    const chinese = readLocaleSection(windowsLocale, "zh-CN");
    for (const stage of stages) {
      compareWording(english, chinese, stage.labelKey, stage.labels, `phase ${stage.id}`);
    }
    for (const [name, message] of Object.entries(fixture.messages ?? {})) {
      compareWording(english, chinese, message.labelKey, message.labels, `message ${name}`);
    }
  }

  const macosEnglish = readText(macosEnglishPath);
  const macosChinese = readText(macosChinesePath);
  if (macosEnglish && macosChinese) {
    const englishStrings = parseStringsFile(macosEnglish);
    const chineseStrings = parseStringsFile(macosChinese);
    for (const stage of stages) {
      compareLocalizable(
        englishStrings,
        chineseStrings,
        stage.labels,
        `phase ${stage.id}`,
      );
    }
    for (const [name, message] of Object.entries(fixture.messages ?? {})) {
      compareLocalizable(englishStrings, chineseStrings, message.labels, `message ${name}`);
    }
  }

  const macosSettings = readText(macosSettingsPath);
  if (macosSettings) {
    if (!/startupAnimationEnabled/.test(macosSettings)) {
      failures.push("macOS settings must expose the startup animation switch");
    }
    if (!/"settings\.startupAnimationEnabled"/.test(macosSettings)) {
      failures.push("macOS settings must persist the startup animation switch");
    }
  }

  const windowsSettingsType = readText(windowsSettingsTypePath);
  if (windowsSettingsType && !/showStartupAnimation:\s*boolean/.test(windowsSettingsType)) {
    failures.push("Windows settings must expose the startup animation switch");
  }
  const windowsSettingsDefault = readText(windowsSettingsDefaultPath);
  if (windowsSettingsDefault && !/showStartupAnimation:\s*true/.test(windowsSettingsDefault)) {
    failures.push("Windows settings must enable the startup animation by default");
  }
}

// The Windows phase table keeps one phase per line, so every line that declares
// an identifier is read on its own. Reading line by line keeps the failure
// message table, which also carries wording, out of the phase comparison.
function parseWindowsStageLines(source) {
  const entries = [];
  for (const line of source.split("\n")) {
    const id = /\bid:\s*"([A-Za-z]+)"/.exec(line);
    if (!id) continue;
    const labelKey = /\blabelKey:\s*"([^"]+)"/.exec(line);
    const progress = /\bprogress:\s*(\d+)/.exec(line);
    const wording = /\blabels:\s*\{\s*en:\s*"((?:[^"\\]|\\.)*)"\s*,\s*zhHans:\s*"((?:[^"\\]|\\.)*)"\s*\}/.exec(
      line,
    );
    entries.push({
      id: id[1],
      labelKey: labelKey?.[1],
      progress: progress ? Number(progress[1]) : undefined,
      en: wording ? JSON.parse(`"${wording[1]}"`) : undefined,
      zhHans: wording ? JSON.parse(`"${wording[2]}"`) : undefined,
    });
  }
  return entries;
}

function readLocaleSection(source, language) {
  const marker = new RegExp(`^\\s*"${language}":\\s*\\{`, "m");
  const match = marker.exec(source);
  if (!match) {
    failures.push(`Windows locale catalog ${language} is missing`);
    return null;
  }
  const start = match.index + match[0].length;
  const rest = source.slice(start);
  const next = /^\s*"(?:en-US|zh-CN)":\s*\{/m.exec(rest);
  return next ? rest.slice(0, next.index) : rest;
}

function parseLocaleEntries(section) {
  const entries = new Map();
  if (!section) return entries;
  const pattern = /"((?:[^"\\]|\\.)*)"\s*:\s*"((?:[^"\\]|\\.)*)"/g;
  for (const match of section.matchAll(pattern)) {
    entries.set(JSON.parse(`"${match[1]}"`), JSON.parse(`"${match[2]}"`));
  }
  return entries;
}

function parseStringsFile(source) {
  const entries = new Map();
  const pattern = /^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";/gm;
  for (const match of source.matchAll(pattern)) {
    entries.set(JSON.parse(`"${match[1]}"`), JSON.parse(`"${match[2]}"`));
  }
  return entries;
}

function compareWording(englishSection, chineseSection, labelKey, labels, subject) {
  const english = parseLocaleEntries(englishSection);
  const chinese = parseLocaleEntries(chineseSection);
  if (english.get(labelKey) !== labels.en) {
    failures.push(`Windows English wording for ${subject} differs from the contract`);
  }
  if (chinese.get(labelKey) !== labels.zhHans) {
    failures.push(`Windows Chinese wording for ${subject} differs from the contract`);
  }
}

function compareLocalizable(englishStrings, chineseStrings, labels, subject) {
  if (englishStrings.get(labels.en) !== labels.en) {
    failures.push(`macOS English wording for ${subject} is missing`);
  }
  if (chineseStrings.get(labels.en) !== labels.zhHans) {
    failures.push(`macOS Chinese wording for ${subject} differs from the contract`);
  }
}

if (failures.length) {
  console.error(failures.join("\n"));
  process.exitCode = 1;
} else {
  console.log("Startup feedback contract verified: shared fixture, phases, timings, and wording match");
}
