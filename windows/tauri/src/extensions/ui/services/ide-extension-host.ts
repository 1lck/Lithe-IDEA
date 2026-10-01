import type { ExtensionManifest } from "@/extensions/types/extension-manifest";

const defaultDependencies = {
  async list() {
    const host = await import("@/features/host-api/mcp-connection");
    return host.authorizedIdeWorkspaceIDs();
  },
  async call(workspaceID: string, name: string, args: Record<string, unknown>) {
    const host = await import("@/features/host-api/mcp-connection");
    return host.callAuthorizedIdeCapability(workspaceID, name, args);
  },
};

/** The worker receives only the same project grant used by MCP, never native bridge access. */
export async function callIdeExtensionService(
  manifest: Pick<ExtensionManifest, "permissions">,
  method: string,
  params: unknown[],
  dependencies = defaultDependencies,
): Promise<unknown> {
  if (manifest.permissions?.ide !== true)
    throw new Error("Extension does not have IDE capability permission");
  if (method === "ide.authorizedWorkspaceIDs") return dependencies.list();
  if (method !== "ide.call") throw new Error("Unknown IDE extension method");
  const [workspaceID, name, args] = params;
  if (
    typeof workspaceID !== "string" ||
    typeof name !== "string" ||
    !args ||
    typeof args !== "object" ||
    Array.isArray(args) ||
    new TextEncoder().encode(JSON.stringify(args)).length > 65_536
  ) {
    throw new Error("Supply an authorized workspace ID, tool name and bounded JSON arguments");
  }
  return dependencies.call(workspaceID, name, args as Record<string, unknown>);
}
