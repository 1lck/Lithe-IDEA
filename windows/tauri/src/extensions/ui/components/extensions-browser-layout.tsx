import type { ReactNode } from "react";
import { useDefaultLayout } from "react-resizable-panels";
import { ResizableHandle, ResizablePanel, ResizablePanelGroup } from "@/ui/resizable";
import { useTranslation } from "@/i18n/locale-provider";

/** Settings has its own list/detail width constraints, independent of the workbench breakpoint. */
export function ExtensionsBrowserLayout({
  presentation,
  children,
}: {
  presentation: "workbench" | "settings";
  children: [ReactNode, ReactNode];
}) {
  if (presentation === "workbench") {
    return (
      <div className="grid min-h-0 flex-1 grid-cols-1 lg:grid-cols-[minmax(380px,1fr)_minmax(340px,440px)]">
        {children}
      </div>
    );
  }
  return <SettingsExtensionsLayout>{children}</SettingsExtensionsLayout>;
}

function SettingsExtensionsLayout({ children }: { children: [ReactNode, ReactNode] }) {
  const { t } = useTranslation();
  const { defaultLayout, onLayoutChanged } = useDefaultLayout({
    id: "lithe.settings.pluginList",
    panelIds: ["plugins", "details"],
    onlySaveAfterUserInteractions: true,
    storage: window.localStorage,
  });
  return (
    <div className="min-h-0 flex-1">
      <ResizablePanelGroup
        orientation="horizontal"
        defaultLayout={defaultLayout}
        onLayoutChanged={onLayoutChanged}
      >
        <ResizablePanel id="plugins" defaultSize="230px" minSize="200px">
          {children[0]}
        </ResizablePanel>
        <ResizableHandle aria-label={t("settings.resizePlugins")} />
        <ResizablePanel id="details" minSize="160px">
          {children[1]}
        </ResizablePanel>
      </ResizablePanelGroup>
    </div>
  );
}
