import { getPathIdentity } from "@/utils/path-helpers";
import { IndexingSettingsError } from "./indexing-settings-error";

export const DIRECTORY_MARKS = [
  "plain", "sources", "resources", "excluded", "module", "package",
] as const;
export type DirectoryMark = (typeof DIRECTORY_MARKS)[number];
export type DirectoryAction =
  | { kind: "setRole"; role: Exclude<DirectoryMark, "excluded"> }
  | { kind: "exclude" }
  | { kind: "cancelExclusion" };
export type DirectoryMarks = Record<string, DirectoryMark>;

export const directoryMarksStorageKey = (root: string) =>
  `lithe.workspace-directory-marks.${getPathIdentity(root).replace(/\/+$/, "")}`;

/** Tree presentation and indexing must reject the same damaged preference. */
export function readDirectoryMarks(root: string, storage?: Storage): DirectoryMarks {
  let raw: string | null;
  try { raw = (storage ?? window.localStorage).getItem(directoryMarksStorageKey(root)); }
  catch (cause) { throw new IndexingSettingsError("readFailed", cause); }
  if (raw === null) return {};
  let value: unknown;
  try { value = JSON.parse(raw); }
  catch (cause) { throw new IndexingSettingsError("invalidSettings", cause); }
  if (!value || typeof value !== "object" || Array.isArray(value))
    throw new IndexingSettingsError("invalidSettings");
  const settings = value as { version?: unknown; marks?: unknown };
  if (
    settings.version !== 1 || !settings.marks ||
    Array.isArray(settings.marks) || typeof settings.marks !== "object" ||
    !Object.entries(settings.marks).every(([path, mark]) =>
      !path.startsWith("/") && !path.includes("\\") && !path.includes(":") &&
      !path.split("/").includes("..") && DIRECTORY_MARKS.includes(mark as DirectoryMark))
  ) throw new IndexingSettingsError("invalidSettings");
  return settings.marks as DirectoryMarks;
}
