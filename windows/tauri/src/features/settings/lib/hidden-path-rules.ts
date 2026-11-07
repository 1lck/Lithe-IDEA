import { useSettingsStore } from "@/features/settings/stores/settings.store";

/** Hidden-path rules in the shape Rust Core requests accept (`hiddenDirectoryNames`, `hiddenFilePatterns`). */
export interface HiddenPathRules {
  hiddenDirectoryNames: string[];
  hiddenFilePatterns: string[];
}

/**
 * Maps the user's hidden-path settings onto Core's request fields without changing the stored
 * values. Core owns the built-in defaults and interprets every rule, so search, snapshots and
 * local history all hide the same paths. A plain directory name hides that folder at any depth;
 * a directory entry with a wildcard or a separator becomes a folder glob (`dist/**` style).
 */
export function hiddenPathRules(
  settings: { hiddenDirectoryPatterns: readonly string[]; hiddenFilePatterns: readonly string[] } = useSettingsStore.getState()
    .settings,
): HiddenPathRules {
  const hiddenDirectoryNames: string[] = [];
  const hiddenFilePatterns = [...settings.hiddenFilePatterns];
  for (const entry of settings.hiddenDirectoryPatterns) {
    const name = entry.trim().replace(/\/+$/, "");
    if (!name) continue;
    if (/[*?/]/.test(name)) hiddenFilePatterns.push(`${name}/`);
    else hiddenDirectoryNames.push(name);
  }
  return { hiddenDirectoryNames, hiddenFilePatterns };
}
