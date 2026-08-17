export const TEXT_FILE_ENCODING = "UTF-8";

const BYTES_PER_MEGABYTE = 1024 * 1024;

interface JsHeapMemory {
  usedJSHeapSize: number;
  totalJSHeapSize: number;
}

export interface FooterMemoryUsage {
  usedBytes: number;
  totalBytes: number;
}

export function formatMemoryMegabytes(bytes: number): string {
  const megabytes = bytes / BYTES_PER_MEGABYTE;
  return `${megabytes.toFixed(1)} MB`;
}

export function readJsHeapMemory(): FooterMemoryUsage | null {
  const memory = (performance as Performance & { memory?: JsHeapMemory }).memory;
  if (!memory || !Number.isFinite(memory.usedJSHeapSize) || !Number.isFinite(memory.totalJSHeapSize)) {
    return null;
  }

  return {
    usedBytes: memory.usedJSHeapSize,
    totalBytes: memory.totalJSHeapSize,
  };
}

export function countUniqueGitChanges(files: Array<{ path: string }> | undefined): number {
  if (!files || files.length === 0) return 0;
  return new Set(files.map((file) => file.path)).size;
}
