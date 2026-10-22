import { countGitChangedFiles } from "@/features/git/utils/git-untracked-directories";
export const TEXT_FILE_ENCODING = "UTF-8";

const BYTES_PER_MEGABYTE = 1024 * 1024;

export function formatMemoryMegabytes(bytes: number): string {
  const megabytes = bytes / BYTES_PER_MEGABYTE;
  return `${megabytes.toFixed(1)} MB`;
}

/** Changed files; a summarized untracked directory counts the files it stands for. */
export function countUniqueGitChanges(
  files: Array<{ path: string; untrackedFileCount?: number }> | undefined,
): number {
  return countGitChangedFiles(files);
}
