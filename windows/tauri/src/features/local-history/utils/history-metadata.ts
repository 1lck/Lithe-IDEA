export interface LocalHistoryEntry {
  id: string;
  file_path: string;
  file_name: string;
  created_at: number;
  size: number;
  content_hash: string;
  reason: string;
  label?: string | null;
}

export interface CoreHistoryEntry {
  id: string;
  timestamp: number;
  relativePath: string;
  reason: string;
  contentPath: string;
  byteCount: number;
  label?: string;
}

/** Windows workspace identity is case-insensitive and independent of slash spelling. */
export async function historyWorkspaceIdentity(root: string): Promise<string> {
  const normalized = root.replace(/\\/g, "/").replace(/\/+$/, "").toLowerCase();
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(normalized));
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

export const toLocalEntry = (entry: CoreHistoryEntry): LocalHistoryEntry => ({
  id: entry.id,
  file_path: entry.relativePath,
  file_name: entry.relativePath.split("/").pop() ?? entry.relativePath,
  created_at: entry.timestamp * 1000,
  size: entry.byteCount,
  content_hash: "",
  reason: entry.reason,
  label: entry.label ?? null,
});
