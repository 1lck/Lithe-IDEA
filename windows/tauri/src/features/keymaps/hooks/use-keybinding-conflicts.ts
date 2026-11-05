import { useEffect, useState } from "react";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { useKeymapStore } from "../stores/keymaps.store";
import type { Command } from "../types/keymaps.types";
import { analyzeKeybindings, conflictingCommandIds } from "../utils/binding-conflicts";
import { keymapRegistry } from "../utils/registry";

interface ConflictInfo {
  hasConflict: boolean;
  conflictingCommands: Command[];
}

const NO_CONFLICT: ConflictInfo = { hasConflict: false, conflictingCommands: [] };

/** Conflicts of one command among the final effective bindings, as computed by Core. */
export function useKeybindingConflicts(currentCommandId: string): ConflictInfo {
  const userKeybindings = useKeymapStore.use.keybindings();
  const preset = useSettingsStore((state) => state.settings.keybindingPreset);
  const [info, setInfo] = useState<ConflictInfo>(NO_CONFLICT);

  useEffect(() => {
    let cancelled = false;
    void analyzeKeybindings({
      preset,
      registryKeybindings: keymapRegistry.getAllKeybindings(),
      userKeybindings,
    })
      .then((analysis) => {
        if (cancelled) return;
        const conflictingCommands = conflictingCommandIds(analysis, currentCommandId)
          .map((id) => keymapRegistry.getCommand(id))
          .filter((command): command is Command => command !== undefined);
        setInfo(
          conflictingCommands.length > 0
            ? { hasConflict: true, conflictingCommands }
            : NO_CONFLICT,
        );
      })
      .catch(() => {
        if (!cancelled) setInfo(NO_CONFLICT);
      });
    return () => {
      cancelled = true;
    };
  }, [currentCommandId, preset, userKeybindings]);

  return info;
}
