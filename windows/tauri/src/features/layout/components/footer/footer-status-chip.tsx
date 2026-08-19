import type { ButtonHTMLAttributes, ComponentProps, ReactNode } from "react";
import { cn } from "@/utils/cn";

const footerStatusChipClassName =
  "font-sans inline-flex h-(--lithe-chrome-control-height) max-w-50 shrink-0 items-center gap-1 rounded-md border-0 px-1.5 ui-text-chrome leading-none text-subtle-foreground transition-colors hover:bg-accent hover:text-foreground";

export function FooterStatusChip({
  className,
  children,
  ...props
}: ButtonHTMLAttributes<HTMLButtonElement> & { children: ReactNode }) {
  return (
    <button type="button" className={cn(footerStatusChipClassName, className)} {...props}>
      {children}
    </button>
  );
}

export function FooterStatusLabel({
  className,
  children,
  ...props
}: ComponentProps<"span"> & { children: ReactNode }) {
  return (
    <span
      className={cn(
        footerStatusChipClassName,
        "hover:bg-transparent hover:text-subtle-foreground",
        className,
      )}
      {...props}
    >
      {children}
    </span>
  );
}
