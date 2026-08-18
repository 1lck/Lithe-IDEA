import { Avatar } from "@/ui/avatar";
import { useTranslation } from "@/i18n/locale-provider";
import Tooltip from "@/ui/tooltip";
import { cn } from "@/utils/cn";

export function CollaborationAvatar({ name, online }: { name: string; online?: boolean }) {
  return (
    <span className="relative shrink-0">
      <Avatar name={name} className="size-7" />
      {online !== undefined ? (
        <span
          className={cn(
            "-right-0.5 -bottom-0.5 absolute size-2 rounded-full border border-background bg-subtle-foreground/55",
            online && "bg-primary",
          )}
        />
      ) : null}
    </span>
  );
}

export function PresenceStatusDot({ online }: { online: boolean }) {
  const { t } = useTranslation();

  if (!online) return null;

  return (
    <Tooltip content={t("collaboration.online")} side="top">
      <span className="block size-2 rounded-full bg-primary" />
    </Tooltip>
  );
}
