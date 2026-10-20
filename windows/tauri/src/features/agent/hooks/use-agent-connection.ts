import { useSyncExternalStore } from "react";
import { agentConnection } from "../stores/agent-connection-service";
import type { AgentConnectionSnapshot } from "../stores/agent-connection.model";

/**
 * Subscribe the panel to the window's connection.
 *
 * The model is a stable singleton, so every component reads the same snapshot
 * and re-renders only when the reduction actually changed it.
 */
export function useAgentSnapshot(): AgentConnectionSnapshot {
  const model = agentConnection();
  return useSyncExternalStore(model.subscribe, model.getSnapshot, model.getSnapshot);
}
