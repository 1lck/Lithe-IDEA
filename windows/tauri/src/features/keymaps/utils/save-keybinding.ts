import { useSettingsStore } from "@/features/settings/stores/settings.store";
import type { KeybindingPreset } from "../defaults/keybinding-presets";
import { useKeymapStore } from "../stores/keymaps.store";
import type { Keybinding } from "../types/keymaps.types";
import { assertNoKeybindingConflicts } from "./binding-conflicts";
import { normalizeUserKeybinding } from "./keybinding-import-export";
import { keymapRegistry } from "./registry";

/**
 * Throws a `KeybindingConflictError` unless Core confirms none of `bindings` collides with
 * another command's effective binding (defaults, preset or user). Nothing is stored here;
 * `preset` is the preset that will be active once the bindings are applied.
 */
export async function assertUserKeybindingsAllowed(
  bindings: Keybinding[],
  options: { preset?: KeybindingPreset } = {},
): Promise<Keybinding[]> {
  const normalized = bindings
    .map((binding) => normalizeUserKeybinding(binding))
    .filter((binding): binding is Keybinding => binding !== null);
  const commandIds = new Set(normalized.map((binding) => binding.command));
  await assertNoKeybindingConflicts(
    {
      preset: options.preset ?? useSettingsStore.getState().settings.keybindingPreset,
      registryKeybindings: keymapRegistry.getAllKeybindings(),
      userKeybindings: [
        ...useKeymapStore
          .getState()
          .keybindings.filter((binding) => !commandIds.has(binding.command)),
        ...normalized,
      ],
    },
    [...commandIds],
  );
  return normalized;
}

/** Stores one edited binding only if it does not collide with an effective binding. */
export async function saveUserKeybinding(binding: Keybinding): Promise<void> {
  const [allowed] = await assertUserKeybindingsAllowed([binding]);
  if (allowed) await useKeymapStore.getState().actions.addKeybinding(allowed);
}
