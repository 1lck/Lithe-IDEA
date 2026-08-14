import type { ComponentProps } from "react";
import { cn } from "@/utils/cn";

export function WorkbenchFullscreenSurface({ className, style, ...props }: ComponentProps<"div">) {
  return (
    <div
      data-slot="workbench-fullscreen-surface"
      className={cn("fixed inset-x-0 z-10040 overflow-hidden bg-background", className)}
      style={{
        top: "var(--lithe-title-bar-height)",
        bottom: "var(--lithe-footer-height)",
        ...style,
      }}
      {...props}
    />
  );
}
