/** Read-only host binding of the existing vcs.detectRoots/ownerOf results. */
export interface VcsScope {
  workspaceId: string;
  workspaceRoot: string;
  incarnation: string;
}
export interface VcsRoot {
  id: string;
  vcs: string;
  path: string;
  mapped: boolean;
}
export interface VcsProvider {
  vcs: string;
  displayName: string;
  origin: { kind: "builtIn" | "plugin"; pluginID?: string };
}
export interface VcsSnapshot {
  generation: number;
  workspaceId: string;
  workspaceRoot: string;
  detection: {
    providers: VcsProvider[];
    roots: VcsRoot[];
    ambiguous: Array<{ id: string; vcs: string[] }>;
    unusedMappings: Array<{ id: string; vcs: string }>;
    truncated: boolean;
    rejected: unknown[];
    conflicts: unknown[];
  };
}
export interface VcsOwnership {
  generation: number;
  owners: Array<{ path: string; root: string | null }>;
  commonRoot: VcsRoot | null;
  complete: boolean;
}
export interface VcsRootPort {
  detect(scope: VcsScope): Promise<VcsSnapshot>;
  owners(scope: VcsScope, generation: number, paths: string[]): Promise<VcsOwnership>;
  close(scope: VcsScope): Promise<void>;
  deadline(callback: () => void): () => void;
}
export interface VcsRootState {
  status: "idle" | "loading" | "ready" | "failed";
  snapshot: VcsSnapshot | null;
  error: unknown;
}
