import { executeCore, type CoreRequest, type CoreResponse } from "@/core/lithe-core-client";

export type JavaWorkspaceChangeKind = "ignored" | "source" | "buildConfiguration" | "other";

export interface JavaWorkspacePolicy {
  shouldStart: boolean;
  representativeJavaPath?: string;
  changes: Array<{ path: string; kind: JavaWorkspaceChangeKind }>;
}

type JavaWorkspacePolicyExecutor = (
  request: CoreRequest<{ workspacePaths: string[]; changedPaths: string[] }>,
) => Promise<CoreResponse<JavaWorkspacePolicy>>;

/** Executes the Rust-owned Java activation and file-change policy. */
export async function resolveJavaWorkspacePolicy(
  workspacePaths: string[],
  changedPaths: string[] = [],
  executor: JavaWorkspacePolicyExecutor = executeCore,
): Promise<JavaWorkspacePolicy> {
  const operationId = crypto.randomUUID();
  const response = await executor({
    id: operationId,
    operationId,
    command: "java.workspacePolicy",
    payload: { workspacePaths, changedPaths },
  });
  if (response.ok) return response.data;
  const error = new Error(response.error.message) as Error & { code?: string; details?: string };
  error.code = response.error.code;
  error.details = response.error.details;
  throw error;
}
