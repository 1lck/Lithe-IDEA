import { useUIState } from "@/features/window/stores/ui-state.store";

export type EncodingPickerMode = "choose" | "reopen" | "save";

let mode: EncodingPickerMode = "choose";

export function openEncodingPicker(nextMode: EncodingPickerMode): void {
  mode = nextMode;
  const state = useUIState.getState();
  state.openCommandPaletteView("encoding");
  state.setIsCommandPaletteVisible(true);
}

export function getEncodingPickerMode(): EncodingPickerMode {
  return mode;
}
