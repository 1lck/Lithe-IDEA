/**
 * Builds the bundled `idea-icons` file icon theme from IntelliJ platform
 * assets: copies SVGs into
 * src/extensions/bundled/icon-themes/idea/icons and emits the theme's
 * extension.json manifest.
 *
 * Usage (run from windows/tauri):
 *   bun scripts/generate-idea-file-icons.ts --source <intellij-community>/platform/icons/src [--check]
 *
 * Dark appearance uses the `<name>_dark.svg` sibling when present; the light
 * appearance always uses the base file. Copied SVGs keep their embedded
 * Apache-2.0 copyright comments untouched.
 */
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";

interface FileThemeMapping {
  fileExtensions: Record<string, string>;
  filenames: Record<string, string>;
  folders: Record<string, string>;
  defaultFile: string;
  defaultFolder: string;
}

const REPO_ROOT = resolve(import.meta.dir, "..");
const MAPPING_PATH = join(import.meta.dir, "idea-file-icon-mappings.json");
const THEME_DIR = join(REPO_ROOT, "src/extensions/bundled/icon-themes/idea");
const MANIFEST_PATH = join(THEME_DIR, "extension.json");

function parseArgs(): { source: string | null; check: boolean } {
  const argv = process.argv.slice(2);
  let source: string | null = null;
  let check = false;
  for (let i = 0; i < argv.length; i += 1) {
    if (argv[i] === "--source" && argv[i + 1]) {
      source = resolve(argv[i + 1]);
      i += 1;
    } else if (argv[i] === "--check") {
      check = true;
    }
  }
  return { source, check };
}

function sha(buffer: Buffer): string {
  return createHash("sha256").update(buffer).digest("hex");
}

function definitionName(source: string): string {
  const file = source.split("/").pop() ?? source;
  return `idea-${file.replace(/\.svg$/, "")}`;
}

function themeAssetPath(source: string, dark: boolean): string {
  const rel = dark ? source.replace(/\.svg$/, "_dark.svg") : source;
  return `./icons/${rel}`;
}

const { source: sourceRoot, check } = parseArgs();
if (!sourceRoot) {
  console.error("Missing --source <intellij-community>/platform/icons/src");
  process.exit(1);
}

const mapping = JSON.parse(readFileSync(MAPPING_PATH, "utf8")) as FileThemeMapping;

const entries = new Map<string, string>(); // definition name -> source svg
const mapKeys = new Map<string, string>(); // ".ts" / "Dockerfile" / "src" -> definition name

function registerEntries(record: Record<string, string>): string[] {
  const keys: string[] = [];
  for (const [key, source] of Object.entries(record)) {
    const name = definitionName(source);
    entries.set(name, source);
    mapKeys.set(key, name);
    keys.push(key);
  }
  return keys;
}

const extensionKeys = registerEntries(mapping.fileExtensions);
const filenameKeys = registerEntries(mapping.filenames);
const folderKeys = registerEntries(mapping.folders);
entries.set(definitionName(mapping.defaultFile), mapping.defaultFile);
entries.set(definitionName(mapping.defaultFolder), mapping.defaultFolder);

const missing: string[] = [];
const darkVariants = new Map<string, boolean>(); // definition name -> has dark pair
for (const [name, source] of entries) {
  if (!existsSync(join(sourceRoot, source))) {
    missing.push(source);
    continue;
  }
  const hasDark = existsSync(join(sourceRoot, source.replace(/\.svg$/, "_dark.svg")));
  darkVariants.set(name, hasDark);
}
if (missing.length > 0) {
  console.error(missing.map((s) => `source SVG not found: ${s}`).join("\n"));
  process.exit(1);
}

const iconDefinitions: Record<string, string> = {};
const lightIconDefinitions: Record<string, string> = {};
const fileExtensions: Record<string, string> = {};
const filenames: Record<string, string> = {};
const folders: Record<string, string> = {};
const expandedFolders: Record<string, string> = {};

for (const [name, source] of entries) {
  const hasDark = darkVariants.get(name) === true;
  iconDefinitions[name] = themeAssetPath(source, hasDark);
  lightIconDefinitions[name] = themeAssetPath(source, false);
}
for (const key of extensionKeys) fileExtensions[key] = mapKeys.get(key)!;
for (const key of filenameKeys) filenames[key] = mapKeys.get(key)!;
for (const key of folderKeys) {
  folders[key] = mapKeys.get(key)!;
  expandedFolders[key] = mapKeys.get(key)!;
}

const manifest = {
  $schema: "https://lithe.dev/schemas/extension.json",
  id: "lithe.icon-theme.idea-icons",
  name: "idea-icons",
  displayName: "IDEA Icons",
  publisher: "Lithe",
  categories: ["Icon Theme"],
  version: "0.1.0",
  description:
    "File icons from the IntelliJ platform icon set (intellij-community, Apache-2.0, embedded per-file copyright notices preserved).",
  icons: [
    {
      id: "idea-icons",
      name: "IDEA Icons",
      description:
        "File icons from the IntelliJ platform icon set (intellij-community, Apache-2.0).",
      defaultFile: definitionName(mapping.defaultFile),
      defaultFolder: definitionName(mapping.defaultFolder),
      defaultFolderOpen: definitionName(mapping.defaultFolder),
      iconDefinitions,
      lightIconDefinitions,
      fileExtensions,
      filenames,
      folders,
      expandedFolders,
    },
  ],
};

const filesToCopy: Array<[string, boolean]> = [];
for (const [name, source] of entries) {
  filesToCopy.push([source, false]);
  if (darkVariants.get(name) === true) {
    filesToCopy.push([source.replace(/\.svg$/, "_dark.svg"), true]);
  }
}

if (check) {
  const problems: string[] = [];
  const current = readFileSync(MANIFEST_PATH, "utf8");
  const expected = JSON.stringify(manifest, null, 2) + "\n";
  if (current !== expected) {
    problems.push("extension.json is out of date; rerun the generator");
  }
  for (const [rel] of filesToCopy) {
    const copied = join(THEME_DIR, "icons", rel);
    if (!existsSync(copied)) {
      problems.push(`missing copied asset: idea/icons/${rel}`);
    } else if (sha(readFileSync(copied)) !== sha(readFileSync(join(sourceRoot, rel)))) {
      problems.push(`copied asset differs from source: idea/icons/${rel}`);
    }
  }
  if (problems.length > 0) {
    console.error(problems.join("\n"));
    process.exit(1);
  }
  console.log(`idea-icons theme check passed (${entries.size} definitions)`);
  process.exit(0);
}

for (const [rel] of filesToCopy) {
  const dest = join(THEME_DIR, "icons", rel);
  mkdirSync(dirname(dest), { recursive: true });
  writeFileSync(dest, readFileSync(join(sourceRoot, rel)));
}
writeFileSync(MANIFEST_PATH, JSON.stringify(manifest, null, 2) + "\n");
console.log(
  `Copied ${filesToCopy.length} SVGs and emitted idea-icons extension.json (${entries.size} definitions)`,
);
