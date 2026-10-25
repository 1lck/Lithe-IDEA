import { useEffect, useState } from "react";
import { AgentSettingsSection } from "@/features/agent/components/agent-settings-section";
import { useAgentManagement } from "@/features/agent/hooks/use-agent-management";
import { useAgentSnapshot } from "@/features/agent/hooks/use-agent-connection";
import {
  agentDataDirectory, agentWorkspacePath, closeAgentConnection, openAgentConnection,
} from "@/features/agent/stores/agent-connection-service";
import { useSettingsStore } from "../../stores/settings.store";
import { useTranslation } from "@/i18n/locale-provider";

/** Both settings entry points edit the same persisted Agent configuration. */
export function AgentSettingsPanel() {
  const { t } = useTranslation();
  const settings = useSettingsStore((state) => state.settings.agentPanel);
  const updateSetting = useSettingsStore((state) => state.actions.updateSetting);
  const snapshot = useAgentSnapshot();
  const [directory, setDirectory] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    let current = true;
    void agentDataDirectory().then((path) => { if (current) setDirectory(path); })
      .catch((failure) => { if (current) setError(String(failure)); });
    return () => { current = false; };
  }, []);
  const management = useAgentManagement(directory, true);
  const canChangeAuthentication = snapshot.connectionState.status !== "connecting" &&
    !snapshot.isCreatingSession && !Object.values(snapshot.conversations).some((conversation) =>
      conversation.isResponding || conversation.isLoading || conversation.pendingConfigToken !== null ||
      conversation.pendingSteeringToken !== null ||
      conversation.pendingPermissions.length > 0);
  const reconnect = () => {
    const workspace = agentWorkspacePath();
    const current = useSettingsStore.getState().settings.agentPanel;
    void closeAgentConnection().then(() => workspace && current.enabled
      ? openAgentConnection(workspace, current) : undefined)
      .catch((failure) => setError(String(failure)));
  };
  return <div className="space-y-3">
    <h2 className="font-medium">{t("settings.tabs.agents")}</h2>
    <AgentSettingsSection key={settings.agentId} settings={settings} management={management}
      onChange={(next) => void updateSetting("agentPanel", next)} onReconnect={reconnect}
      canChangeAuthentication={canChangeAuthentication} />
    {error ? <div role="alert" className="text-warning">{error}</div> : null}
  </div>;
}
