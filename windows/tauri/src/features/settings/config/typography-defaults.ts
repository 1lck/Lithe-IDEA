import type { Platform } from "@tauri-apps/plugin-os";

import { IS_MAC, IS_WINDOWS } from "@/utils/platform";

export const DEFAULT_UI_FONT_FAMILY = IS_MAC
  ? "SF Pro Text"
  : IS_WINDOWS
    ? "Microsoft YaHei UI"
    : "Noto Sans CJK SC";
export const DEFAULT_MONO_FONT_FAMILY = "Geist Mono";

const DEFAULT_MONO_FONT_FALLBACK =
  'ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, "Liberation Mono", monospace';
const WINDOWS_MONO_FONT_FALLBACK =
  'Consolas, "Cascadia Mono", "Cascadia Code", "Courier New", ui-monospace, monospace';
const LINUX_MONO_FONT_FALLBACK =
  'JetBrains Mono, "Noto Sans Mono", "DejaVu Sans Mono", "Liberation Mono", ui-monospace, monospace';
const DEFAULT_SANS_FONT_FALLBACK =
  'ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif';
const WINDOWS_SANS_FONT_FALLBACK =
  '"Segoe UI", system-ui, -apple-system, BlinkMacSystemFont, Roboto, "Helvetica Neue", Arial, sans-serif';
const LINUX_SANS_FONT_FALLBACK =
  '"Noto Sans CJK SC", "Noto Sans SC", Ubuntu, Cantarell, system-ui, "DejaVu Sans", sans-serif';

export const DEFAULT_CODE_FONT_SIZE = 14;
export const DEFAULT_UI_FONT_SIZE = 13;

export function getTypographyFontFallbacks(platform: Platform) {
  if (platform === "windows") {
    return {
      mono: WINDOWS_MONO_FONT_FALLBACK,
      sans: WINDOWS_SANS_FONT_FALLBACK,
    };
  }
  if (platform === "linux") {
    return {
      mono: LINUX_MONO_FONT_FALLBACK,
      sans: LINUX_SANS_FONT_FALLBACK,
    };
  }
  return {
    mono: DEFAULT_MONO_FONT_FALLBACK,
    sans: DEFAULT_SANS_FONT_FALLBACK,
  };
}
