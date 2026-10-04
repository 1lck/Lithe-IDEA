/** IntelliJ Islands ships nine RecentProject.ColorN.MainToolbarGradientStart colors. */
export const PROJECT_GRADIENT_COLOR_COUNT = 9;

const FNV_OFFSET_BASIS = 14_695_981_039_346_656_037n;
const FNV_PRIME = 1_099_511_628_211n;
const UINT64_MASK = (1n << 64n) - 1n;

/**
 * Picks the 1-based Islands project color for a project. IntelliJ assigns colors round-robin
 * and persists them; Lithe derives them from the path so a project keeps its color without
 * extra storage, using the same 64-bit FNV-1a hash as macOS ProjectIdentityAppearance.
 * Windows paths are compared case-insensitively with either separator.
 */
export function getProjectGradientColorIndex(projectPath: string): number {
  const normalized = projectPath.replace(/\\/g, "/").replace(/\/+$/, "").toLowerCase();
  let hash = FNV_OFFSET_BASIS;
  for (const byte of new TextEncoder().encode(normalized)) {
    hash = ((hash ^ BigInt(byte)) * FNV_PRIME) & UINT64_MASK;
  }
  return Number(hash % BigInt(PROJECT_GRADIENT_COLOR_COUNT)) + 1;
}
