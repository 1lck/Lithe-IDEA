/**
 * Asks Core which shortcuts collide once defaults, the preset and user overrides are layered.
 * The grammar of binding strings and the layering rules live in Core; this file only
 * projects the stores into Core's layer format. It never runs on the key-dispatch path.
 */
import { invoke } from "@/platform/tauri-core";
import type { Settings } from "@/features/settings/types/settings.types";
import { getKeybindingPresetDefinition } from "../defaults/keybinding-presets";
import type { Keybinding } from "../types/keymaps.types";

export interface BindingConflict {
  key: string;
  when: string | null;
  commands: string[];
}

interface ConflictAnalysis {
  conflicts: BindingConflict[];
  invalid: { command: string; key: string; code: string }[];
}

export interface KeybindingLayersInput {
  preset: Settings["keybindingPreset"];
  registryKeybindings: Keybinding[];
  userKeybindings: Keybinding[];
}

/** Rejected save: the proposed binding is already in force for other commands. */
export class KeybindingConflictError extends Error {
  constructor(readonly commands: string[]) {
    super("keybinding_conflict");
  }
}

function toEntries(bindings: Keybinding[]) {
  return bindings.map(({ command, key, when, enabled }) => ({ command, key, when, enabled }));
}

export function analyzeKeybindings({
  preset,
  registryKeybindings,
  userKeybindings,
}: KeybindingLayersInput): Promise<ConflictAnalysis> {
  const { overrides, disabledCommands } = getKeybindingPresetDefinition(preset);
  return invoke<ConflictAnalysis>("keymap.analyzeConflicts", {
    platform: "windows",
    layers: [
      { entries: toEntries(registryKeybindings) },
      { entries: toEntries(overrides), disabledCommands },
      { entries: toEntries(userKeybindings) },
    ],
  });
}

/** Command IDs that share an effective key and `when` clause with `commandId`. */
export function conflictingCommandIds(analysis: ConflictAnalysis, commandId: string): string[] {
  return analysis.conflicts
    .filter((conflict) => conflict.commands.includes(commandId))
    .flatMap((conflict) => conflict.commands.filter((command) => command !== commandId));
}

/** Throws before anything is stored if the proposed layers make any of `commandIds` collide. */
export async function assertNoKeybindingConflicts(
  input: KeybindingLayersInput,
  commandIds: string[],
): Promise<void> {
  const analysis = await analyzeKeybindings(input);
  const commands = new Set(commandIds.flatMap((id) => conflictingCommandIds(analysis, id)));
  if (commands.size > 0) throw new KeybindingConflictError([...commands]);
}
