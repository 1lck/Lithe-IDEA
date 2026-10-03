/**
 * Copies IntelliJ platform icon SVGs into the Lithe icon funnel and emits the
 * generated asset map consumed by `src/ui/icons.tsx`.
 *
 * Usage (run from windows/tauri):
 *   bun scripts/generate-idea-icons.ts --source <intellij-community>/platform/icons/src [--check]
 *
 * The mapping file (scripts/idea-icon-mappings.json) is the single source of
 * truth for which Lithe icon exports use IntelliJ assets; every other export
 * keeps its lucide fallback. Source paths are repo-relative and resolved
 * against --source, so no machine-specific path is persisted. Each copied SVG
 * keeps its embedded Apache-2.0 copyright comment untouched.
 */
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";

interface MappingEntry {
  icon: string;
  source: string | null;
  /**
   * Repo-relative path under src/ui/icons/idea to copy to, for assets that
   * live outside platform/icons/src (for example the terminal glyph that only
   * ships in the Jewel showcase resources). Defaults to `source`.
   */
  destination?: string;
  /**
   * IntelliJ's dedicated 20x20 artwork (`*@20x20.svg`) used by the main toolbar and tool window
   * stripes. Rendered when an icon is requested with `large`; the 16px art is not just scaled.
   */
  source20?: string;
  /** Like `destination`, for `source20`. */
  destination20?: string;
  note?: string;
}

interface MappingFile {
  icons: MappingEntry[];
}

const REPO_ROOT = resolve(import.meta.dir, "..");
const MAPPING_PATH = join(import.meta.dir, "idea-icon-mappings.json");
const ICONS_TSX_PATH = join(REPO_ROOT, "src/ui/icons.tsx");
const ASSETS_DIR = join(REPO_ROOT, "src/ui/icons/idea");
const GENERATED_TS_PATH = join(REPO_ROOT, "src/ui/icons/idea-assets.generated.ts");

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

function toIdentifier(icon: string): string {
  return icon.replace(/Icon$/, "").replace(/^./, (c) => c.toLowerCase());
}

function sha(buffer: Buffer): string {
  return createHash("sha256").update(buffer).digest("hex");
}

const { source: sourceRoot, check } = parseArgs();
if (!sourceRoot) {
  console.error("Missing --source <intellij-community>/platform/icons/src");
  process.exit(1);
}

const mapping = JSON.parse(readFileSync(MAPPING_PATH, "utf8")) as MappingFile;
const iconsTsx = readFileSync(ICONS_TSX_PATH, "utf8");

interface PlannedIcon {
  icon: string;
  /** Light/dark paths relative to --source. */
  lightSource: string;
  darkSource: string | null;
  /** Light/dark paths relative to src/ui/icons/idea. */
  light: string;
  dark: string | null;
  /** The optional 20x20 artwork, with the same light/dark layout. */
  large: PlannedVariant | null;
}

type PlannedVariant = Omit<PlannedIcon, "icon" | "large">;

/** [destination relative to ASSETS_DIR, source relative to --source] per variant. */
function assetPairs(p: PlannedVariant & { large?: PlannedVariant | null }): Array<[string, string]> {
  const pairs: Array<[string, string]> = [[p.light, p.lightSource]];
  if (p.dark && p.darkSource) pairs.push([p.dark, p.darkSource]);
  if (p.large) pairs.push(...assetPairs(p.large));
  return pairs;
}

const planned: PlannedIcon[] = [];
const missingSources: string[] = [];

function planVariant(source: string, destination: string): PlannedVariant | null {
  if (!existsSync(join(sourceRoot as string, source))) {
    missingSources.push(source);
    return null;
  }
  const darkRel = source.replace(/\.svg$/, "_dark.svg");
  const hasDark = existsSync(join(sourceRoot as string, darkRel));
  return {
    lightSource: source,
    darkSource: hasDark ? darkRel : null,
    light: destination,
    dark: hasDark ? destination.replace(/\.svg$/, "_dark.svg") : null,
  };
}
const unknownExports: string[] = [];
const duplicateIcons: string[] = [];

for (const entry of mapping.icons) {
  if (planned.some((p) => p.icon === entry.icon)) {
    duplicateIcons.push(entry.icon);
    continue;
  }
  if (!new RegExp(`export const ${entry.icon} =`).test(iconsTsx)) {
    unknownExports.push(entry.icon);
    continue;
  }
  if (!entry.source) {
    continue;
  }
  const base = planVariant(entry.source, entry.destination ?? entry.source);
  const large = entry.source20
    ? planVariant(entry.source20, entry.destination20 ?? entry.source20)
    : null;
  if (!base || (entry.source20 && !large)) continue;
  planned.push({ icon: entry.icon, ...base, large });
}

planned.sort((a, b) => a.icon.localeCompare(b.icon));

const failures = [
  ...missingSources.map((s) => `source SVG not found: ${s}`),
  ...unknownExports.map((i) => `not exported from src/ui/icons.tsx: ${i}`),
  ...duplicateIcons.map((i) => `duplicate mapping entry: ${i}`),
];
if (failures.length > 0) {
  console.error(failures.join("\n"));
  process.exit(1);
}

let generated = `// AUTO-GENERATED by scripts/generate-idea-icons.ts — do not edit by hand.\n`;
generated += `// Mapping source: scripts/idea-icon-mappings.json (paths relative to the\n`;
generated += `// intellij-community platform/icons/src checkout passed via --source).\n`;
generated += `// Keys are icon export display names resolved by createIconComponent.\n\n`;

for (const p of planned) {
  generated += `import ${toIdentifier(p.icon)}Light from "./idea/${p.light}?url";\n`;
  if (p.dark) {
    generated += `import ${toIdentifier(p.icon)}Dark from "./idea/${p.dark}?url";\n`;
  }
  if (p.large) {
    generated += `import ${toIdentifier(p.icon)}LargeLight from "./idea/${p.large.light}?url";\n`;
    if (p.large.dark) {
      generated += `import ${toIdentifier(p.icon)}LargeDark from "./idea/${p.large.dark}?url";\n`;
    }
  }
}
generated += `\nexport interface IdeaIconAsset {\n  light: string;\n  dark: string;\n`;
generated += `  /** IntelliJ @20x20 toolbar and stripe artwork, when it exists. */\n`;
generated += `  large?: { light: string; dark: string };\n}\n\n`;
generated += `export const ideaIconAssets: Record<string, IdeaIconAsset> = {\n`;
for (const p of planned) {
  const id = toIdentifier(p.icon);
  const darkId = p.dark ? `${id}Dark` : `${id}Light`;
  const largeDarkId = p.large?.dark ? `${id}LargeDark` : `${id}LargeLight`;
  const large = p.large ? `, large: { light: ${id}LargeLight, dark: ${largeDarkId} }` : "";
  generated += `  ${p.icon}: { light: ${id}Light, dark: ${darkId}${large} },\n`;
}
generated += `};\n`;

if (check) {
  const problems: string[] = [];
  if (readFileSync(GENERATED_TS_PATH, "utf8") !== generated) {
    problems.push("src/ui/icons/idea-assets.generated.ts is out of date; rerun the generator");
  }
  for (const p of planned) {
    for (const [rel, src] of assetPairs(p)) {
      const copied = join(ASSETS_DIR, rel);
      if (!existsSync(copied)) {
        problems.push(`missing copied asset: src/ui/icons/idea/${rel}`);
      } else if (sha(readFileSync(copied)) !== sha(readFileSync(join(sourceRoot, src)))) {
        problems.push(`copied asset differs from source: src/ui/icons/idea/${rel}`);
      }
    }
  }
  if (problems.length > 0) {
    console.error(problems.join("\n"));
    process.exit(1);
  }
  console.log(`idea-icons check passed (${planned.length} mapped icons)`);
  process.exit(0);
}

for (const p of planned) {
  for (const [rel, src] of assetPairs(p)) {
    const dest = join(ASSETS_DIR, rel);
    mkdirSync(dirname(dest), { recursive: true });
    writeFileSync(dest, readFileSync(join(sourceRoot, src)));
  }
}
writeFileSync(GENERATED_TS_PATH, generated);
console.log(
  `Copied ${planned.reduce((n, p) => n + assetPairs(p).length, 0)} SVGs and emitted idea-assets.generated.ts (${planned.length} icons mapped)`,
);
