import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import { WrenchIcon } from "@/ui/icons";
import { useUIState } from "@/features/window/stores/ui-state.store";
import { applyRightToolWindowIntent } from "@/features/layout/actions/right-tool-window-actions";
import { useBuildWorkspace } from "../hooks/use-build-workspace";

export function BuildTrigger({ className }: { className?: string }) {
  const { t } = useTranslation(), { snapshot } = useBuildWorkspace();
  const active = useUIState(state => state.isRightSidebarVisible && state.activeRightSidebarView === "build");
  if (!snapshot.entries.length && snapshot.status !== "failed") return null;
  return <Button variant="ghost" size="icon-sm" active={active} aria-pressed={active} className={className}
    tooltip={t("build.window.title")} tooltipSide="left" aria-label={t("build.window.title")}
    onClick={() => applyRightToolWindowIntent("build", "toggle")}><WrenchIcon className="size-5" /></Button>;
}
