import { create } from "zustand";
import { invoke } from "@/platform/tauri-core";
import { hostControl, IdeCapabilities, type IdePermissions } from "./ide-capabilities";

import { McpConnectionManager, type McpConnectionState } from "./mcp-lifecycle";

export const useMcpConnections = create<McpConnectionState>(() => ({
  connections: {},
  error: null,
}));
const manager = new McpConnectionManager(
  {
    createAPI: (workspaceID, root, permissions) =>
      new IdeCapabilities(workspaceID, root, permissions),
    paths: () => invoke("ide_host_paths"),
    control: hostControl,
    schedule: (callback) => setTimeout(callback, 200),
    cancel: (timer) => clearTimeout(timer),
  },
  (state) => useMcpConnections.setState(state),
);

export const disableMcp = (workspaceID: string) => manager.disable(workspaceID);
export const enableMcp = (workspaceID: string, root: string, permissions: IdePermissions) =>
  manager.enable(workspaceID, root, permissions);
export const closeMcpConnections = () => manager.closeAll();

/** Plugin hosts use the same granted connection and cannot select their own permissions. */
export function authorizedIdeWorkspaceIDs() {
  return Object.entries(useMcpConnections.getState().connections)
    .filter(([, connection]) => !connection.closed && connection.api.isCurrent())
    .map(([id]) => id)
    .sort();
}

export async function callAuthorizedIdeCapability(
  workspaceID: string,
  name: string,
  args: Record<string, unknown>,
) {
  const connection = useMcpConnections.getState().connections[workspaceID];
  if (!connection || connection.closed)
    return {
      error: { code: "UNAVAILABLE", message: "Enable access for this project in Lithe settings" },
    };
  return connection.api.call(name, args);
}
