import { useState } from "react";
import { writeText } from "@tauri-apps/plugin-clipboard-manager";
import { Button } from "@/ui/button";
import { useTranslation } from "@/i18n/locale-provider";
import { disableMcp, enableMcp, useMcpConnections } from "./mcp-connection";

export function McpSettings({ workspaceID, root }: { workspaceID: string; root: string }) {
  const connection = useMcpConnections((s) => s.connections[workspaceID]);
  const error = useMcpConnections((s) => s.error);
  const { t } = useTranslation();
  const [configure, setConfigure] = useState(false);
  const [execute, setExecute] = useState(false);
  const [busy, setBusy] = useState(false);
  const [copyError, setCopyError] = useState<string | null>(null);
  return (
    <section className="space-y-3 rounded-md border border-border p-4">
      <p className="text-sm text-text-lighter">{t("settings.mcp.description")}</p>
      <p className="text-sm text-text-lighter">{t("settings.mcp.plugins")}</p>
      <label className="flex items-center gap-2 text-sm">
        <input
          type="checkbox"
          checked={connection?.api.permissions.configure ?? configure}
          disabled={!!connection || busy}
          onChange={(e) => setConfigure(e.target.checked)}
        />
        {t("settings.mcp.allowConfigure")}
      </label>
      <label className="flex items-center gap-2 text-sm">
        <input
          type="checkbox"
          checked={connection?.api.permissions.execute ?? execute}
          disabled={!!connection || busy}
          onChange={(e) => setExecute(e.target.checked)}
        />
        {t("settings.mcp.allowExecute")}
      </label>
      <div className="flex gap-2">
        <Button
          disabled={busy}
          onClick={async () => {
            setBusy(true);
            try {
              if (connection) await disableMcp(workspaceID);
              else await enableMcp(workspaceID, root, { configure, execute });
            } finally {
              setBusy(false);
            }
          }}
        >
          {connection ? t("settings.mcp.disable") : t("settings.mcp.enable")}
        </Button>
        {connection && (
          <Button
            onClick={() => {
              void writeText(connection.configuration).catch((e) => setCopyError(String(e)));
            }}
          >
            {t("settings.mcp.copyConfiguration")}
          </Button>
        )}
      </div>
      {connection && (
        <pre className="max-h-40 overflow-auto whitespace-pre-wrap break-all text-xs">
          {connection.configuration}
        </pre>
      )}
      {(error || copyError) && (
        <p role="alert" className="text-sm text-red-500">
          {error || copyError}
        </p>
      )}
    </section>
  );
}
