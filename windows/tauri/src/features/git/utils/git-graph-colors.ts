export const GRAPH_COLORS = ["#55d68b", "#65a9ff", "#d77eea", "#f3aa59", "#e76c72", "#56c7cf"];

export const GRAPH_COLOR_COUNT = GRAPH_COLORS.length;

export function graphColor(index: number): string {
  return GRAPH_COLORS[((index % GRAPH_COLOR_COUNT) + GRAPH_COLOR_COUNT) % GRAPH_COLOR_COUNT];
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

/** Stable palette slot for a reference name, so a branch keeps its color. */
export function graphColorIndexForName(name: string): number {
  return ((javaStringHashCode(name) % GRAPH_COLOR_COUNT) + GRAPH_COLOR_COUNT) % GRAPH_COLOR_COUNT;
}
