import { KeyIcon as KeyRound } from "@/ui/icons";
import type { AcpEvent, AcpPermissionOption } from "@/features/ai/types/acp.types";
import Badge from "@/ui/badge";
import { Button, type ButtonVariant } from "@/ui/button";
import { useTranslation } from "@/i18n/locale-provider";

export type AcpPermissionRequest = {
  requestId: string;
  description: string;
  permissionType: string;
  resource: string;
  options: Extract<AcpEvent, { type: "permission_request" }>["options"];
};

const fallbackOptions: AcpPermissionOption[] = [
  { id: "reject", name: "Deny", kind: "reject_once" },
  { id: "allow", name: "Allow", kind: "allow_once" },
];

function getOptionLabel(option: AcpPermissionOption, t: (key: string) => string) {
  switch (option.kind) {
    case "allow_once":
      return t("ai.allow");
    case "allow_always":
      return t("ai.always");
    case "reject_once":
      return t("ai.deny");
    case "reject_always":
      return t("ai.never");
    default:
      return option.name;
  }
}

function getOptionTooltip(option: AcpPermissionOption, t: (key: string) => string) {
  switch (option.kind) {
    case "allow_once":
      return t("ai.allowOnce");
    case "allow_always":
      return t("ai.alwaysAllowRequestType");
    case "reject_once":
      return t("ai.denyOnce");
    case "reject_always":
      return t("ai.alwaysDenyRequestType");
    default:
      return option.name;
  }
}

function getOptionVariant(option: AcpPermissionOption): ButtonVariant {
  switch (option.kind) {
    case "allow_always":
      return "accent";
    case "allow_once":
      return "default";
    case "reject_always":
    case "reject_once":
      return "danger";
    default:
      return "ghost";
  }
}

function isApproval(option: AcpPermissionOption) {
  return option.kind === "allow_once" || option.kind === "allow_always";
}

export function AcpPermissionPrompt({
  permission,
  queuedCount,
  onRespond,
}: {
  permission: AcpPermissionRequest;
  queuedCount: number;
  onRespond: (approved: boolean, optionId?: string) => void;
}) {
  const { t } = useTranslation();
  const summary = (
    permission.description ||
    [permission.permissionType, permission.resource].filter(Boolean).join(" ")
  ).trim();
  const options = permission.options.length > 0 ? permission.options : fallbackOptions;

  return (
    <div className="bg-transparent px-3 pt-2 ui-text-sm">
      <div className="flex h-9 items-center gap-2 rounded-lg border border-border/70 bg-background/92 px-2 shadow-(--shadow-card)">
        <KeyRound className="size-3.5 shrink-0 text-subtle-foreground" weight="duotone" />
        <div
          className="min-w-0 flex-1 truncate text-foreground"
          title={`${permission.permissionType} - ${permission.resource}`}
        >
          <span className="font-medium text-muted-foreground">{t("ai.permission")}</span>
          <span className="px-1.5 text-subtle-foreground">/</span>
          <span className="font-mono">{summary}</span>
        </div>
        {queuedCount > 0 ? (
          <Badge variant="muted" size="compact" className="shrink-0">
            +{queuedCount}
          </Badge>
        ) : null}
        <div className="flex shrink-0 items-center gap-1">
          {options.map((option) => {
            return (
              <Button
                key={option.id}
                type="button"
                variant={getOptionVariant(option)}
                size="xs"
                onClick={() =>
                  onRespond(
                    isApproval(option),
                    permission.options.length > 0 ? option.id : undefined,
                  )
                }
                tooltip={getOptionTooltip(option, t)}
                tooltipSide="top"
              >
                {getOptionLabel(option, t)}
              </Button>
            );
          })}
        </div>
      </div>
    </div>
  );
}
