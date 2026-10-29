import type { VcsWriteAction, VcsWriteSnapshot } from "./vcs-action-types";
import type { VcsQuerySnapshot, VcsReadQuery } from "./vcs-query-types";
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
  mappings?: {
    source: string;
    revision: string | null;
    entries: Array<{ id: string; vcs: string }>;
  };
  watchError?: string | null;
  mappingChoices?: Array<{ id: string; vcs: string[] }>;
}
export interface VcsInvalidation {
  workspaceId: string;
  incarnation: string;
  generation: number;
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
  subscribe?(scope: VcsScope, changed: (event: VcsInvalidation) => void): Promise<() => void>;
  debounce?(callback: () => void): () => void;
  saveMapping?(
    scope: VcsScope,
    generation: number,
    revision: string | null,
    id: string,
    vcs: string | null,
  ): Promise<void>;
  status?(
    scope: VcsScope,
    generation: number,
    rootId: string,
    requestId: string,
  ): Promise<VcsStatusSnapshot>;
  cancelStatus?(scope: VcsScope, requestId: string): Promise<void>;
  statusDeadline?(callback: () => void): () => void;
  write?(
    scope: VcsScope,
    generation: number,
    rootId: string,
    requestId: string,
    statusId: string,
    action: VcsWriteAction,
  ): Promise<VcsWriteSnapshot>;
  writeDeadline?(callback: () => void): () => void;
  query?(
    scope: VcsScope,
    generation: number,
    rootId: string,
    requestId: string,
    query: VcsReadQuery,
  ): Promise<VcsQuerySnapshot>;
}
export interface VcsStatusSnapshot {
  requestId: string;
  generation: number;
  rootId: string;
  vcs: string;
  rootIdentity?: string;
  operation?: "status";
  capabilities?: Record<string, number>;
  result: {
    head: {
      revision: { id: string; display: string; kind: string } | null;
      branch: string | null;
      location: string | null;
    } | null;
    changes: Array<{ path: string; oldPath: string | null; status: string; flags: string[] }>;
    truncated: boolean;
  };
}
export interface VcsRootState {
  status: "idle" | "loading" | "ready" | "failed";
  snapshot: VcsSnapshot | null;
  error: unknown;
}
