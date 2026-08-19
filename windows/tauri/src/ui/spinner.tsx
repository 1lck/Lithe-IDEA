import type { ComponentProps } from "react";
import { useTranslation } from "@/i18n/locale-provider";
import { cn } from "@/utils/cn";

type SpinnerProps = Omit<ComponentProps<"span">, "children"> & {
  label?: string;
  showLabel?: boolean;
  compact?: boolean;
};

function Spinner({
  className,
  label,
  showLabel = false,
  compact = false,
  ...props
}: SpinnerProps) {
  const { t } = useTranslation();
  const resolvedLabel = label ?? t("ui.loading");
  const icon = (
    <span
      role={showLabel ? undefined : "status"}
      aria-hidden={showLabel || undefined}
      aria-label={showLabel ? undefined : resolvedLabel}
      className={cn(
        "inline-block shrink-0 animate-spin rounded-full border-2 border-current border-r-transparent",
        compact ? "size-3" : "size-4",
        !showLabel && className,
      )}
      {...props}
    />
  );

  if (!showLabel) {
    return icon;
  }

  return (
    <span
      role="status"
      aria-live="polite"
      aria-label={resolvedLabel}
      className={cn(
        "inline-flex items-center gap-2 font-sans ui-text-sm text-subtle-foreground",
        className,
      )}
    >
      {icon}
      <span>{resolvedLabel}</span>
    </span>
  );
}

export { Spinner };
export type { SpinnerProps };
