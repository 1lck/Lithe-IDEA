// Adapted from IntelliJ DefaultColorGenerator, Apache-2.0.
// Copyright 2000-2024 JetBrains s.r.o. and contributors.
// See macos/Resources/GitGraph/NOTICE.txt and the owning Git graph Agent Note.
/** IDEA's signed color ID generates a hue; it is never reduced to a palette slot. */
export function graphColor(colorId: number, isDark = false): string {
  if (colorId === 0) return "var(--foreground)";
  const component = (multiplier: number, offset: number) =>
    Math.abs(((Math.imul(colorId, multiplier) + offset) | 0) % 100) + 70;
  const r = component(200, 30),
    g = component(130, 50),
    b = component(90, 100);
  const max = Math.max(r, g, b),
    min = Math.min(r, g, b);
  let hue = 0;
  if (max !== min) {
    const red = Math.fround((max - r) / (max - min));
    const green = Math.fround((max - g) / (max - min));
    const blue = Math.fround((max - b) / (max - min));
    hue =
      r === max
        ? Math.fround(blue - green)
        : g === max
          ? Math.fround(Math.fround(2 + red) - blue)
          : Math.fround(Math.fround(4 + green) - red);
    hue = Math.fround(hue / 6);
    if (hue < 0) hue = Math.fround(hue + 1);
  }
  // Color.RGBtoHSB / HSBtoRGB use float32 intermediates, including rounding.
  const saturation = Math.fround(0.6),
    brightness = Math.fround(isDark ? 0.6 : 0.7);
  const h = Math.fround(Math.fround(hue - Math.floor(hue)) * 6);
  const f = Math.fround(h - Math.floor(h));
  const p = Math.fround(brightness * Math.fround(1 - saturation));
  const q = Math.fround(brightness * Math.fround(1 - Math.fround(saturation * f)));
  const t = Math.fround(brightness * Math.fround(1 - Math.fround(saturation * Math.fround(1 - f))));
  const channels = [
    [brightness, t, p],
    [q, brightness, p],
    [p, brightness, t],
    [p, q, brightness],
    [t, p, brightness],
    [brightness, p, q],
  ][Math.floor(h) % 6];
  return `rgb(${channels.map((channel) => Math.floor(Math.fround(Math.fround(channel * 255) + 0.5))).join(", ")})`;
}

/**
 * Java `String.hashCode` over UTF-16 code units. IDEA's graph coloring keys a
 * branch's color off this value, so matching it keeps the identity stable across
 * renders and topology changes.
 */
export function javaStringHashCode(value: string): number {
  let hash = 0;
  for (let index = 0; index < value.length; index += 1) {
    hash = (Math.imul(hash, 31) + value.charCodeAt(index)) | 0;
  }
  return hash;
}

/** Stable full Java color ID for a principal reference fragment. */
export function graphColorIdForName(name: string): number {
  return javaStringHashCode(name);
}
