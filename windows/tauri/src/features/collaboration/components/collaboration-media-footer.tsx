import { MicrophoneIcon as Mic, MonitorIcon as Monitor } from "@/ui/icons";
import { Button } from "@/ui/button";
import { useTranslation } from "@/i18n/locale-provider";
import { SidebarFooter } from "@/ui/sidebar";

type ShareState = "idle" | "active" | "error";

export function CollaborationMediaFooter({
  workspaceName,
  micState,
  screenState,
  onlineCount,
  streamStatus,
  isFollowing,
  onToggleMic,
  onToggleScreenShare,
  onStopFollowing,
}: {
  workspaceName: string;
  micState: ShareState;
  screenState: ShareState;
  onlineCount: number;
  streamStatus: string;
  isFollowing: boolean;
  onToggleMic: () => void;
  onToggleScreenShare: () => void;
  onStopFollowing: () => void;
}) {
  const { t } = useTranslation();

  return (
    <SidebarFooter>
      <div className="flex min-w-0 items-center gap-1 px-1 py-1">
        <Button
          type="button"
          variant={micState === "error" ? "danger" : "ghost"}
          active={micState === "active"}
          tooltip={
            micState === "active" ? t("collaboration.stopMic") : t("collaboration.startMic")
          }
          tooltipSide="top"
          onClick={onToggleMic}
          size="icon-sm"
        >
          <Mic />
        </Button>
        <Button
          type="button"
          variant={screenState === "error" ? "danger" : "ghost"}
          active={screenState === "active"}
          tooltip={
            screenState === "active"
              ? t("collaboration.stopScreenShare")
              : t("collaboration.shareScreen")
          }
          tooltipSide="top"
          onClick={onToggleScreenShare}
          size="icon-sm"
        >
          <Monitor />
        </Button>
        <div className="ui-text-sm min-w-0 flex-1 truncate px-1">
          <span className="font-medium text-foreground">{workspaceName}</span>
          <span className="px-1 text-subtle-foreground">·</span>
          <span className="text-subtle-foreground">
            {t("collaboration.onlineCount", { count: onlineCount })}
          </span>
          <span className="px-1 text-subtle-foreground">·</span>
          <span className="text-subtle-foreground">{streamStatus}</span>
        </div>
        {isFollowing ? (
          <Button
            type="button"
            variant="ghost"
            size="xs"
            className="ml-auto"
            onClick={onStopFollowing}
          >
            {t("collaboration.stopFollowing")}
          </Button>
        ) : null}
      </div>
    </SidebarFooter>
  );
}
