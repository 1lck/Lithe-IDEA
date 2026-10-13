import type { Window as TauriWindow } from "@tauri-apps/api/window";
import {
  CopyIcon as Restore,
  MinusIcon as Minus,
  SquareIcon as Square,
  XIcon as X,
} from "@/ui/icons";
import { requestWindowClose } from "@/features/window/utils/request-window-close";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import { ChromeGroup } from "@/ui/chrome";
import { cn } from "@/utils/cn";
import { IS_WINDOWS } from "@/utils/platform";

interface WindowControlsProps {
  currentWindow: TauriWindow | null;
  isMaximized: boolean;
  onMaximizedChange: (isMaximized: boolean) => void;
}

// Use Windows' caption glyphs so the controls match the native title bar.
const WINDOW_CONTROL_GLYPHS = {
  minimize: "\uE921",
  maximize: "\uE922",
  restore: "\uE923",
  close: "\uE8BB",
} as const;

export function WindowControls({
  currentWindow,
  isMaximized,
  onMaximizedChange,
}: WindowControlsProps) {
  const { t } = useTranslation();
  const handleMinimize = async () => {
    try {
      await currentWindow?.minimize();
    } catch (error) {
      console.error("Error minimizing window:", error);
    }
  };

  const handleToggleMaximize = async () => {
    try {
      await currentWindow?.toggleMaximize();
      const maximized = await currentWindow?.isMaximized();
      if (typeof maximized === "boolean") {
        onMaximizedChange(maximized);
      }
    } catch (error) {
      console.error("Error toggling maximize:", error);
    }
  };

  const handleClose = () => {
    requestWindowClose();
  };

  return (
    <ChromeGroup
      gap={IS_WINDOWS ? "none" : "tight"}
      className={cn(IS_WINDOWS && "h-(--lithe-title-bar-height)")}
    >
      <Button
        onClick={handleMinimize}
        variant="ghost"
        className={cn("pointer-events-auto", IS_WINDOWS && "h-full w-14 min-w-14 rounded-none")}
        size="icon-xs"
        tooltip={t("window.minimize")}
        tooltipSide="bottom"
        tooltipTriggerClassName={IS_WINDOWS ? "h-full" : undefined}
        aria-label={t("window.minimize")}
      >
        {IS_WINDOWS ? <WindowControlGlyph kind="minimize" /> : <Minus weight="bold" />}
      </Button>
      <Button
        onClick={handleToggleMaximize}
        variant="ghost"
        className={cn("pointer-events-auto", IS_WINDOWS && "h-full w-14 min-w-14 rounded-none")}
        size="icon-xs"
        tooltip={isMaximized ? t("window.restore") : t("window.maximize")}
        tooltipSide="bottom"
        tooltipTriggerClassName={IS_WINDOWS ? "h-full" : undefined}
        aria-label={isMaximized ? t("window.restore") : t("window.maximize")}
      >
        {IS_WINDOWS ? (
          <WindowControlGlyph kind={isMaximized ? "restore" : "maximize"} />
        ) : isMaximized ? (
          <Restore />
        ) : (
          <Square />
        )}
      </Button>
      <Button
        onClick={handleClose}
        variant="danger"
        className={cn(
          "pointer-events-auto group hover:text-white",
          IS_WINDOWS && "h-full w-14 min-w-14 rounded-none hover:bg-destructive",
        )}
        size="icon-xs"
        tooltip={t("window.close")}
        tooltipSide="bottom"
        tooltipTriggerClassName={IS_WINDOWS ? "h-full" : undefined}
        aria-label={t("window.close")}
      >
        {IS_WINDOWS ? <WindowControlGlyph kind="close" /> : <X weight="bold" />}
      </Button>
    </ChromeGroup>
  );
}

function WindowControlGlyph({
  kind,
}: {
  kind: "minimize" | "maximize" | "restore" | "close";
}) {
  return (
    <span
      aria-hidden="true"
      className="inline-flex size-4 shrink-0 select-none items-center justify-center text-xs leading-none"
      style={{ fontFamily: '"Segoe Fluent Icons", "Segoe MDL2 Assets"' }}
    >
      {WINDOW_CONTROL_GLYPHS[kind]}
    </span>
  );
}
