import { Checkbox as CheckboxPrimitive } from "@base-ui/react/checkbox";
import { CheckIcon, MinusIcon } from "@/ui/icons";
import { cn } from "@/utils/cn";

function Checkbox({ className, indeterminate, ...props }: CheckboxPrimitive.Root.Props) {
  return (
    <CheckboxPrimitive.Root
      data-slot="checkbox"
      className={cn(
        "peer relative inline-flex size-4 shrink-0 cursor-pointer items-center justify-center rounded-md border border-border bg-surface text-transparent outline-none transition-[transform,background-color,border-color,color,box-shadow] duration-(--app-duration-fast) ease-(--app-ease-smooth) after:absolute after:-inset-x-3 after:-inset-y-2 active:scale-(--app-press-scale) focus-visible:ring-2 focus-visible:ring-primary/20 data-checked:border-primary data-checked:bg-primary data-checked:text-white data-disabled:cursor-not-allowed data-disabled:opacity-50 aria-invalid:border-destructive aria-invalid:ring-2 aria-invalid:ring-destructive/20",
        className,
      )}
      indeterminate={indeterminate}
      {...props}
    >
      <CheckboxPrimitive.Indicator
        data-slot="checkbox-indicator"
        className="grid place-content-center text-current transition-none"
      >
        {/* A mixed state (some children included) shows a dash instead of a check. */}
        {indeterminate ? (
          <MinusIcon className="size-3" strokeWidth={3} />
        ) : (
          <CheckIcon className="size-3.5" strokeWidth={3} />
        )}
      </CheckboxPrimitive.Indicator>
    </CheckboxPrimitive.Root>
  );
}

export { Checkbox };
