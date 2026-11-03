import { cva, type VariantProps } from "class-variance-authority";
import type { ComponentProps } from "react";
import { Separator } from "@/ui/separator";
import { cn } from "@/utils/cn";

const buttonGroupVariants = cva(
  "flex w-fit items-stretch *:focus-visible:relative *:focus-visible:z-10",
  {
    variants: {
      orientation: {
        horizontal:
          "flex-row [&>[data-slot=button]:not(:first-child)]:rounded-l-none [&>[data-slot=button]:not(:last-child)]:rounded-r-none [&>[data-slot=button]:not(:first-child)]:border-l-0 *:data-[slot=button-group-separator]:h-auto",
        vertical:
          "flex-col [&>[data-slot=button]:not(:first-child)]:rounded-t-none [&>[data-slot=button]:not(:last-child)]:rounded-b-none [&>[data-slot=button]:not(:first-child)]:border-t-0",
      },
      variant: {
        default:
          "rounded-md bg-accent *:data-[slot=button]:bg-transparent *:data-[slot=button]:hover:bg-selected",
        accent:
          "overflow-hidden rounded-md border border-primary/25 bg-primary/10 *:data-[slot=button]:text-primary *:data-[slot=button]:hover:bg-primary/10 *:data-[slot=button-group-separator]:bg-primary/25",
        // IntelliJ default option button: solid fill with white text, and a 1px separator
        // inset from the top and bottom edges. The group dims as a whole when disabled so
        // the fill and the labels fade together.
        primary:
          "overflow-hidden rounded-[4px] bg-primary has-[button:disabled]:opacity-50 *:data-[slot=button]:border-0 *:data-[slot=button]:text-white *:data-[slot=button]:hover:bg-white/10 *:data-[slot=button]:focus-visible:ring-inset *:data-[slot=button]:focus-visible:ring-white/70 *:data-[slot=button]:disabled:opacity-100 *:data-[slot=button-group-separator]:my-1.5 *:data-[slot=button-group-separator]:bg-black/30",
      },
    },
    defaultVariants: {
      orientation: "horizontal",
      variant: "default",
    },
  },
);

function ButtonGroup({
  className,
  orientation = "horizontal",
  variant = "default",
  ...props
}: ComponentProps<"div"> & VariantProps<typeof buttonGroupVariants>) {
  return (
    <div
      role="group"
      data-slot="button-group"
      data-orientation={orientation}
      data-variant={variant}
      className={cn(buttonGroupVariants({ orientation, variant }), className)}
      {...props}
    />
  );
}

function ButtonGroupText({ className, ...props }: ComponentProps<"div">) {
  return (
    <div
      data-slot="button-group-text"
      className={cn(
        "flex items-center gap-2 rounded-md bg-accent px-3 font-medium text-foreground [&_svg]:pointer-events-none [&_svg:not([class*='size-'])]:size-3.5",
        className,
      )}
      {...props}
    />
  );
}

function ButtonGroupSeparator({
  className,
  orientation = "vertical",
  ...props
}: ComponentProps<typeof Separator>) {
  return (
    <Separator
      data-slot="button-group-separator"
      orientation={orientation}
      className={cn(
        "relative m-0 self-stretch bg-border/70 data-[orientation=vertical]:h-auto",
        className,
      )}
      {...props}
    />
  );
}

export { ButtonGroup, ButtonGroupSeparator, ButtonGroupText, buttonGroupVariants };
