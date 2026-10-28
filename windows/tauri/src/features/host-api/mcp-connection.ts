import { create } from "zustand";
import { Channel, invoke } from "@/platform/tauri-core";
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
    now: () => Date.now(),
    open: (args, receive) => {
      const channel = new Channel<unknown>();
      channel.onmessage = (value) => {
        const event = value as { hostID?: unknown; requestID?: unknown };
        if (typeof event?.hostID === "string" && typeof event?.requestID === "string") {
          receive({ hostID: event.hostID, requestID: event.requestID });
        }
      };
      return invoke("ideHost.control", { action: "open", arguments: args }, { ideEvents: channel });
    },
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
