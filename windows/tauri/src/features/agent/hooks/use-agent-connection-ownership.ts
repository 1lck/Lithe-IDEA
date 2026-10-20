import { useCallback, useEffect, useState } from "react";
import {
  agentConnectionMatches,
  closeAgentConnection,
  openAgentConnection,
} from "../stores/agent-connection-service";
import type { AgentPanelSettings } from "../types/agent-settings.types";

/**
 * Claim the window-wide Agent connection for the visible workspace.
 *
 * Cached workspace split views keep their panel mounted while another project
 * owns the shared connection. Activation, not the workspace's own root path, is
 * what makes a panel ask for ownership; hidden panels never reconnect.
 */
export function useAgentConnectionOwnership({
  isActive,
  workspacePath,
  settings,
}: {
  isActive: boolean;
  workspacePath: string | null;
  settings: AgentPanelSettings;
}): {
  ownsConnection: boolean;
  claim: (workspace: string, settings: AgentPanelSettings) => void;
} {
  const [connectedWorkspace, setConnectedWorkspace] = useState<string | null>(null);
  const claim = useCallback((workspace: string, nextSettings: AgentPanelSettings) => {
    setConnectedWorkspace(agentConnectionMatches(workspace, nextSettings) ? workspace : null);
  }, []);

  useEffect(() => {
    if (!isActive) {
      setConnectedWorkspace(null);
      return;
    }
    let cancelled = false;
    const complete = () => {
      if (!cancelled && workspacePath !== null) claim(workspacePath, settings);
    };
    setConnectedWorkspace(null);
    if (!settings.enabled) {
      void closeAgentConnection().then(complete).catch(() => undefined);
    } else if (workspacePath !== null) {
      void openAgentConnection(workspacePath, settings).then(complete).catch(() => undefined);
    }
    return () => {
      cancelled = true;
    };
  }, [claim, isActive, settings, workspacePath]);

  return {
    ownsConnection: isActive && workspacePath !== null && connectedWorkspace === workspacePath,
    claim,
  };
}
