import { useMemo } from "react";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { useActiveWorkspaceId } from "@/features/workspace/stores/create-workspace-scoped-store";
import { useTranslation } from "@/i18n/locale-provider";
import { SidebarPanel, SidebarTitleBar } from "@/ui/sidebar";
import { useDeclarativePluginUI } from "../declarative-plugin-ui";
import { nativePanelStates, nativeViewId } from "./native-contributions";
import { nativeUIValidator } from "./native-ui-core";
import { NativePanel } from "./native-panel";
import type { NativeFunctionPort, NativePanelPort } from "./native-ui.types";

/** Production contribution body. Function execution is deliberately injected
 * by the shared function bridge; absent bindings remain unavailable. */
export default function NativeToolWindow({
  view,
  onClose,
  functions,
}: {
  view: string;
  onClose(): void;
  functions?: NativeFunctionPort;
}) {
  const { t } = useTranslation();
  const entry = useDeclarativePluginUI((state) =>
    state.nativeWindows?.find((entry) => nativeViewId(entry) === view),
  );
  const workspaceId = useActiveWorkspaceId();
  const port = useMemo<NativePanelPort>(
    () => ({ validate: nativeUIValidator(), functions }),
    [functions],
  );
  const identity = useMemo(
    () =>
      entry
        ? {
            pluginId: entry.pluginId,
            packageIdentity: entry.packageIdentity,
            windowId: entry.windowId,
            panelId: entry.native.id,
            workspaceId,
            hostWindowId: getCurrentWindow().label,
          }
        : undefined,
    [entry, workspaceId],
  );
  if (!entry || !identity || entry.placement !== "right")
    return (
      <SidebarPanel>
        <SidebarTitleBar title={entry?.title ?? t("pluginNative.title")} />
        <p role="alert" className="p-3">
          {t(entry ? "pluginNative.placementUnavailable" : "pluginNative.unavailable")}
        </p>
      </SidebarPanel>
    );
  return (
    <NativePanel
      identity={identity}
      title={entry.title}
      ui={entry.native}
      port={port}
      store={nativePanelStates}
      onClose={onClose}
    />
  );
}
