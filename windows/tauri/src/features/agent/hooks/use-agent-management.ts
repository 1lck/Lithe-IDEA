import { useCallback, useEffect, useState } from "react";
import {
  installAgent,
  installAgentCli,
  loadAgentManagementStatus,
  uninstallAgent,
  type AgentCliUpdateResult,
  type AgentInstallProgress,
  type AgentManagementStatus,
} from "../services/agent-management";

export interface AgentManagement {
  status: AgentManagementStatus | null;
  error: string | null;
  /** Agent id with an install or removal in flight. */
  busyAgentId: string | null;
  progress: AgentInstallProgress | null;
  /** Last verified CLI update outcome for each agent id. */
  cliUpdates: Record<string, AgentCliUpdateResult>;
  isRefreshing: boolean;
  refresh: () => Promise<void>;
  install: (agentId: string) => Promise<void>;
  installCli: (agentId: string) => Promise<void>;
  uninstall: (agentId: string) => Promise<void>;
}

/**
 * Detection and installs through the shared `agent.*` commands.
 *
 * The panel owns this state because installs are user-initiated and visible:
 * nothing is detected until the Agent settings section is on screen, and the
 * npm transfer counters are shown while they arrive.
 */
export function useAgentManagement(dataDirectory: string | null, enabled: boolean): AgentManagement {
  const [status, setStatus] = useState<AgentManagementStatus | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busyAgentId, setBusyAgentId] = useState<string | null>(null);
  const [progress, setProgress] = useState<AgentInstallProgress | null>(null);
  const [cliUpdates, setCliUpdates] = useState<Record<string, AgentCliUpdateResult>>({});
  const [isRefreshing, setIsRefreshing] = useState(false);

  const refresh = useCallback(async () => {
    if (dataDirectory === null) return;
    setIsRefreshing(true);
    try {
      setStatus(await loadAgentManagementStatus(dataDirectory));
      setError(null);
    } catch (failure) {
      setError(failure instanceof Error ? failure.message : String(failure));
    } finally {
      setIsRefreshing(false);
    }
  }, [dataDirectory]);

  useEffect(() => {
    if (!enabled || dataDirectory === null) return;
    void refresh();
  }, [enabled, dataDirectory, refresh]);

  const install = useCallback(
    async (agentId: string) => {
      if (dataDirectory === null || busyAgentId !== null) return;
      setBusyAgentId(agentId);
      setProgress(null);
      setError(null);
      try {
        await installAgent(dataDirectory, agentId, setProgress);
        setStatus(await loadAgentManagementStatus(dataDirectory));
      } catch (failure) {
        setError(failure instanceof Error ? failure.message : String(failure));
      } finally {
        setProgress(null);
        setBusyAgentId(null);
      }
    },
    [busyAgentId, dataDirectory],
  );

  const uninstall = useCallback(
    async (agentId: string) => {
      if (dataDirectory === null || busyAgentId !== null) return;
      setBusyAgentId(agentId);
      setError(null);
      try {
        await uninstallAgent(dataDirectory, agentId);
        setStatus(await loadAgentManagementStatus(dataDirectory));
      } catch (failure) {
        setError(failure instanceof Error ? failure.message : String(failure));
      } finally {
        setBusyAgentId(null);
      }
    },
    [busyAgentId, dataDirectory],
  );

  const installCli = useCallback(
    async (agentId: string) => {
      if (dataDirectory === null || busyAgentId !== null) return;
      setBusyAgentId(agentId);
      setProgress(null);
      setError(null);
      try {
        const result = await installAgentCli(dataDirectory, agentId, setProgress);
        setCliUpdates((current) => ({ ...current, [agentId]: result }));
        setStatus(await loadAgentManagementStatus(dataDirectory));
      } catch (failure) {
        setError(failure instanceof Error ? failure.message : String(failure));
      } finally {
        setProgress(null);
        setBusyAgentId(null);
      }
    },
    [busyAgentId, dataDirectory],
  );

  return {
    status,
    error,
    busyAgentId,
    progress,
    cliUpdates,
    isRefreshing,
    refresh,
    install,
    installCli,
    uninstall,
  };
}
