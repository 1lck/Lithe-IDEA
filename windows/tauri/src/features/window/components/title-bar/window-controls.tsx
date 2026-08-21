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
    <ChromeGroup gap={IS_WINDOWS ? "none" : "tight"} className={cn(IS_WINDOWS && "h-(--lithe-title-bar-height)")}>
      <Button
        onClick={handleMinimize}
        variant="ghost"
        className={cn("pointer-events-auto", IS_WINDOWS && "h-full w-11 rounded-none")}
        size="icon-xs"
        tooltip={t("window.minimize")}
        tooltipSide="bottom"
        aria-label={t("window.minimize")}
      >
        <Minus weight="bold" />
      </Button>
      <Button
        onClick={handleToggleMaximize}
        variant="ghost"
        className={cn("pointer-events-auto", IS_WINDOWS && "h-full w-11 rounded-none")}
        size="icon-xs"
        tooltip={isMaximized ? t("window.restore") : t("window.maximize")}
        tooltipSide="bottom"
        aria-label={isMaximized ? t("window.restore") : t("window.maximize")}
      >
        {isMaximized ? <Restore /> : <Square />}
      </Button>
      <Button
        onClick={handleClose}
        variant="danger"
        className={cn(
          "pointer-events-auto group hover:text-white",
          IS_WINDOWS && "h-full w-11 rounded-none hover:bg-destructive",
        )}
        size="icon-xs"
        tooltip={t("window.close")}
        tooltipSide="bottom"
        aria-label={t("window.close")}
      >
        <X weight="bold" />
      </Button>
    </ChromeGroup>
  );
}
