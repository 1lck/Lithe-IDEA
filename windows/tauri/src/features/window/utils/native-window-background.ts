const HEX = /^#([0-9a-f]{3}|[0-9a-f]{6}|[0-9a-f]{8})$/i;
const RGB = /^rgba?\(\s*(\d{1,3})\s*[,\s]\s*(\d{1,3})\s*[,\s]\s*(\d{1,3})\s*(?:[,/]\s*[\d.]+%?\s*)?\)$/i;

function channel(value: number): string {
  return Math.min(255, value).toString(16).padStart(2, "0");
}

/**
 * The opaque `#rrggbb` the native window paints before the page's first frame,
 * from a theme's `--background`. Themes use hex or `rgb()`; any other format
 * returns null so the host keeps its current colour instead of guessing.
 */
export function nativeWindowBackground(value: string | undefined): string | null {
  const color = value?.trim() ?? "";
  const hex = HEX.exec(color)?.[1];
  if (hex) {
    const digits = hex.length === 3 ? [...hex].map((digit) => digit + digit).join("") : hex.slice(0, 6);
    return `#${digits.toLowerCase()}`;
  }
  const rgb = RGB.exec(color);
  if (rgb) return `#${channel(Number(rgb[1]))}${channel(Number(rgb[2]))}${channel(Number(rgb[3]))}`;
  return null;
}
