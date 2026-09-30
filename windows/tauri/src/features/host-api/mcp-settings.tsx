import { useState } from "react";
import { writeText } from "@tauri-apps/plugin-clipboard-manager";
import { Button } from "@/ui/button";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { disableMcp, enableMcp, useMcpConnections } from "./mcp-connection";

export function McpSettings({ workspaceID, root }: { workspaceID: string; root: string }) {
  const connection = useMcpConnections((s) => s.connections[workspaceID]);
  const error = useMcpConnections((s) => s.error);
  const chinese = useSettingsStore((s) => s.settings.displayLanguage).startsWith("zh");
  const [configure, setConfigure] = useState(false);
  const [execute, setExecute] = useState(false);
  const [busy, setBusy] = useState(false);
  const [copyError, setCopyError] = useState<string | null>(null);
  const text = (zh: string, en: string) => (chinese ? zh : en);
  return (
    <section className="space-y-3 rounded-md border border-border p-4">
      <h3 className="font-medium">{text("AI 工具连接（MCP）", "AI tool connections (MCP)")}</h3>
      <p className="text-sm text-text-lighter">
        {text(
          "仅授权此项目。连接的 Agent 可以检查环境、运行配置和输出；输出可能包含项目敏感信息。关闭项目或退出 IDE 后连接失效。",
          "Authorizes this project only. Connected agents can inspect environment, run configurations and output, which may contain sensitive project data. Access ends when the project or IDE closes.",
        )}
      </p>
      <p className="text-sm text-text-lighter">
        {text(
          "声明 IDE 权限的已启用插件也可使用此项目授权。",
          "Enabled plugins declaring IDE access can also use this project grant.",
        )}
      </p>
      <label className="flex items-center gap-2 text-sm">
        <input
          type="checkbox"
          checked={connection?.api.permissions.configure ?? configure}
          disabled={!!connection || busy}
          onChange={(e) => setConfigure(e.target.checked)}
        />
        {text(
          "允许修改项目环境和 Maven 配置",
          "Allow project environment and Maven configuration changes",
        )}
      </label>
      <label className="flex items-center gap-2 text-sm">
        <input
          type="checkbox"
          checked={connection?.api.permissions.execute ?? execute}
          disabled={!!connection || busy}
          onChange={(e) => setExecute(e.target.checked)}
        />
        {text(
          "允许运行、构建、重载和停止（会执行项目代码）",
          "Allow run, build, reload and stop (executes project code)",
        )}
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
          {connection ? text("关闭 MCP", "Disable MCP") : text("开启 MCP", "Enable MCP")}
        </Button>
        {connection && (
          <Button
            onClick={() => {
              void writeText(connection.configuration).catch((e) => setCopyError(String(e)));
            }}
          >
            {text("复制 Agent 配置", "Copy agent configuration")}
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
