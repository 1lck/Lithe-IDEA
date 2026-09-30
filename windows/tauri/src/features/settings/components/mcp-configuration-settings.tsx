import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { McpSettings } from "@/features/host-api/mcp-settings";
import { useActiveWorkspaceId } from "@/features/workspace/stores/create-workspace-scoped-store";
import { useTranslation } from "@/i18n/locale-provider";

export function McpConfigurationSettings() {
  const root = useFileSystemStore((state) => state.rootFolderPath);
  const workspaceID = useActiveWorkspaceId();
  const { t } = useTranslation();
  if (!root) return <p>{t("settings.mcp.openProject")}</p>;
  return (
    <div className="space-y-4">
      <p className="break-all text-sm text-subtle-foreground">{root}</p>
      <McpSettings key={`${workspaceID}:${root}`} workspaceID={workspaceID} root={root} />
    </div>
  );
}
