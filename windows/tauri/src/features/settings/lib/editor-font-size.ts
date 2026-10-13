import { DEFAULT_CODE_FONT_SIZE } from "../config/typography-defaults";

export const MIN_EDITOR_FONT_SIZE = 6;
export const MAX_EDITOR_FONT_SIZE = 72;

/** Shared validation for controls, imported settings and persisted settings. */
export function normalizeEditorFontSize(value: unknown): number {
  if (typeof value !== "number" || !Number.isFinite(value)) return DEFAULT_CODE_FONT_SIZE;
  return Math.min(MAX_EDITOR_FONT_SIZE, Math.max(MIN_EDITOR_FONT_SIZE, Math.round(value)));
}
