import { executeCore } from "@/core/lithe-core-client";

/** Build domain semantics and all data decoders stay in the shared Core. */
export function createBuildCore(execute: typeof executeCore) {
  return async function buildCore<T extends Record<string, unknown>>(
    command: string, manifest: Record<string, unknown>, buildSystemID: string, request: unknown, workspaceRoot?: string,
  ): Promise<T> {
    const id = crypto.randomUUID();
    const response = await execute<T & { status: "ok" | "rejected"; error?: { code: string; message: string; field?: string } }>({
      id, operationId: id, command, payload: { manifest, buildSystemID, workspaceRoot, request }, timeoutMilliseconds: 30_000,
    });
    if (!response.ok) throw Object.assign(new Error(response.error.message), response.error);
    if (!response.data || response.data.status !== "ok") {
      const error = response.data?.error;
      if (error && typeof error.code === "string" && typeof error.message === "string") {
        throw Object.assign(new Error(error.message), error);
      }
      throw Object.assign(new Error("invalid_response"), { code: "invalid_response" });
    }
    return response.data;
  };
}

export const buildCore = createBuildCore(executeCore);
