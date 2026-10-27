import { useEffect, useMemo, useState } from "react";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { useActiveWorkspaceId } from "@/features/workspace/stores/create-workspace-scoped-store";
import { useTranslation } from "@/i18n/locale-provider";
import { SidebarPanel, SidebarTitleBar } from "@/ui/sidebar";
import { useDeclarativePluginUI } from "../declarative-plugin-ui";
import { nativePanelStates, nativeViewId } from "./native-contributions";
import { nativeUIValidator } from "./native-ui-core";
import { NativePanel } from "./native-panel";
import { createNativeFunctionPort } from "./native-functions";
import { nativePanelKey } from "./native-panel-state";
import type {
  NativeFunctionPort,
  NativePanelIdentity,
  NativePanelPort,
  NativeContribution,
} from "./native-ui.types";

/** A mounted contribution owns its typed function bridge and exact native
 * handle; provider discovery and execution remain in the shared host owner. */
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
    <BoundNativePanel
      key={nativePanelKey(identity)}
      identity={identity}
      entry={entry}
      functions={functions}
      onClose={onClose}
    />
  );
}

function BoundNativePanel({
  identity,
  entry,
  functions,
  onClose,
}: {
  identity: NativePanelIdentity;
  entry: NativeContribution;
  functions?: NativeFunctionPort;
  onClose(): void;
}) {
  const [owned] = useState(() => (functions ? undefined : createNativeFunctionPort(identity)));
  useEffect(() => () => owned?.dispose(), [owned]);
  const port = useMemo<NativePanelPort>(
    () => ({ validate: nativeUIValidator(), functions: functions ?? owned }),
    [functions, owned],
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
