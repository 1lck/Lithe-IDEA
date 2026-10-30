import { cva, type VariantProps } from "class-variance-authority";
import type { ComponentProps } from "react";
import { cn } from "@/utils/cn";

// The icon column is chosen from the alert root rather than with group-has-*:
// Tailwind compiles group-has to `:has(> svg) *`, whose universal subject made
// every svg inserted anywhere in the app restyle whole subtrees (the file tree
// on each file open).
const alertVariants = cva(
  "group/alert relative grid w-full gap-0.5 rounded-lg border px-2.5 py-2 text-left font-sans ui-text-sm has-[>svg]:grid-cols-[auto_1fr] has-[>svg]:gap-x-2 has-data-[slot=alert-action]:pr-18 [&>svg]:row-span-2 [&>svg]:size-4 [&>svg]:translate-y-0.5 [&:has(>svg)>[data-slot=alert-title]]:col-start-2 [&:has(>svg)>[data-slot=alert-description]]:col-start-2",
  {
    variants: {
      tone: {
        default: "border-border/70 bg-surface/55 text-foreground [&>svg]:text-subtle-foreground",
        info: "border-primary/25 bg-primary/8 text-foreground [&>svg]:text-primary",
        success: "border-success/30 bg-success/8 text-foreground [&>svg]:text-success",
        warning: "border-warning/30 bg-warning/8 text-foreground [&>svg]:text-warning",
        error: "border-destructive/30 bg-destructive/8 text-destructive [&>svg]:text-destructive",
      },
    },
    defaultVariants: {
      tone: "default",
    },
  },
);

function Alert({
  className,
  tone,
  role = "alert",
  ...props
}: ComponentProps<"div"> & VariantProps<typeof alertVariants>) {
  return (
    <div
      data-slot="alert"
      data-tone={tone}
      role={role}
      className={cn(alertVariants({ tone }), className)}
      {...props}
    />
  );
}

function AlertTitle({ className, ...props }: ComponentProps<"div">) {
  return (
    <div
      data-slot="alert-title"
      className={cn("font-medium text-current", className)}
      {...props}
    />
  );
}

function AlertDescription({ className, ...props }: ComponentProps<"div">) {
  return (
    <div
      data-slot="alert-description"
      className={cn(
        "leading-normal text-current/85 [&_a]:underline [&_a]:underline-offset-4",
        className,
      )}
      {...props}
    />
  );
}

function AlertAction({ className, ...props }: ComponentProps<"div">) {
  return (
    <div
      data-slot="alert-action"
      className={cn("absolute top-1.5 right-1.5", className)}
      {...props}
    />
  );
}

export { Alert, AlertAction, AlertDescription, AlertTitle, alertVariants };
