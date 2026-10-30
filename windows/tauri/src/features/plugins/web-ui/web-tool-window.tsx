import { useEffect, useRef, useState, useSyncExternalStore } from "react";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { useActiveWorkspaceId } from "@/features/workspace/stores/create-workspace-scoped-store";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { invoke } from "@/platform/tauri-core";
import { Button } from "@/ui/button";
import { XIcon } from "@/ui/icons";
import { SidebarPanel, SidebarTitleBar } from "@/ui/sidebar";
import { useTranslation } from "@/i18n/locale-provider";
import type { DeclarativeWebToolWindow } from "../declarative-plugin-launch";
import { pluginPlanGuard, subscribePluginActivity } from "../declarative-plugin-lifecycle";
import { getPluginWebAppearance } from "../plugin-web-appearance";
import { openWebPanelSession, webPanelCleanup, type WebPanelSession } from "./web-panel-session";
import { observeWebPanelViewport, webPanelLayout } from "./web-panel-viewport";

export default function WebToolWindow({
  entry,
  onClose,
}: {
  entry: DeclarativeWebToolWindow;
  onClose(): void;
}) {
  const { t } = useTranslation();
  const element = useRef<HTMLDivElement>(null);
  const owned = useRef<WebPanelSession | null>(null);
  const workspaceId = useActiveWorkspaceId();
  const [attempt, retry] = useState(0);
  const [failed, setFailed] = useState(false);
  useEffect(() => {
    if (!element.current) return;
    const body = element.current;
    let disposed = false;
    const runtime = workspaceRuntimeRegistry.getActiveWorkspace();
    const guard = pluginPlanGuard();
    const assertCurrent = () => {
      guard(entry.pluginId);
      if (
        !runtime?.descriptor.path ||
        runtime.status !== "ready" ||
        runtime.descriptor.id !== workspaceId ||
        workspaceRuntimeRegistry.getActiveWorkspace() !== runtime
      )
        throw new Error("plugin.web.staleWorkspace");
    };
    const scope = { pluginId: entry.pluginId, windowId: entry.windowId, workspaceId };
    let session: WebPanelSession | null = null;
    const stopViewport = observeWebPanelViewport(body, (initialLayout) => {
      // A collapsed or not-yet-laid-out slot owns no native resource. Capture
      // the first usable bounds so a later zero-size layout cannot poison mount.
      if (!session && initialLayout.bounds.width > 0 && initialLayout.bounds.height > 0) {
        session = openWebPanelSession(
          JSON.stringify([getCurrentWindow().label, workspaceId, entry.pluginId, entry.windowId]),
          entry.title,
          {
            mount: () => {
              assertCurrent();
              return invoke<{ mountId: string }>("declarative_plugins_mount_web_window", {
                ...scope,
                workspacePath: runtime!.descriptor.path,
                expectedPackageIdentity: entry.packageIdentity,
                appearance: getPluginWebAppearance(),
                mountId: crypto.randomUUID(),
                bounds: initialLayout.bounds,
              });
            },
            layout: (mountId, revision, layout) => {
              assertCurrent();
              return invoke<void>("declarative_plugins_layout_web_window", {
                ...scope,
                mountId,
                revision,
                ...layout,
              });
            },
            unmount: (mountId) =>
              invoke<void>("declarative_plugins_unmount_web_window", { ...scope, mountId }),
          },
          (phase) => {
            if (!disposed && phase === "failed") {
              setFailed(true);
              stopViewport();
              void session?.dispose().catch(() => {}); // Retained by the visible cleanup registry.
            }
          },
        );
        owned.current = session;
      }
      session?.update(initialLayout);
    });
    const stopActivity = subscribePluginActivity((pluginId) => {
      if (pluginId !== entry.pluginId) return;
      try {
        assertCurrent();
      } catch {
        if (!disposed) setFailed(true);
        stopViewport();
        void session?.dispose().catch(() => {});
      }
    });
    return () => {
      disposed = true;
      if (owned.current === session) owned.current = null;
      stopViewport();
      stopActivity();
      void session?.dispose().catch(() => {});
    };
  }, [entry.pluginId, entry.windowId, entry.packageIdentity, workspaceId, attempt]);
  return (
    <SidebarPanel data-plugin-web-panel="">
      <SidebarTitleBar title={entry.title}>
        <Button variant="ghost" size="icon-xs" aria-label={t("pluginWeb.close")} onClick={onClose}>
          <XIcon />
        </Button>
      </SidebarTitleBar>
      <div
        ref={element}
        className="relative min-h-0 flex-1"
        data-plugin-web-body=""
        role="region"
        aria-label={entry.title}
        tabIndex={failed ? -1 : 0}
        onFocus={(event) => {
          if (!failed && event.target === event.currentTarget)
            owned.current?.update({ ...webPanelLayout(event.currentTarget), focus: true });
        }}
      >
        {failed ? (
          <div role="alert" className="p-3 ui-text-sm">
            <p>{t("pluginWeb.failed")}</p>
            <Button
              size="sm"
              onClick={() => {
                setFailed(false);
                retry((value) => value + 1);
              }}
            >
              {t("ui.retry")}
            </Button>
          </div>
        ) : null}
      </div>
    </SidebarPanel>
  );
}

export function PluginWebCleanupNotices() {
  const { t } = useTranslation();
  useSyncExternalStore(webPanelCleanup.subscribe, webPanelCleanup.revision);
  const pending = webPanelCleanup.pending();
  if (!pending.length) return null;
  return (
    <div className="max-h-48 shrink-0 overflow-y-auto">
      {pending.map((owner) => (
        <div
          key={owner.key}
          role="alert"
          className="flex items-center justify-between px-4 ui-text-sm"
        >
          <span>
            {owner.title} · {t("pluginWeb.cleanupFailed")}
          </span>
          <Button
            size="sm"
            disabled={owner.phase === "closing"}
            onClick={() => void owner.dispose().catch(() => {})}
          >
            {t("ui.retry")}
          </Button>
        </div>
      ))}
    </div>
  );
}
