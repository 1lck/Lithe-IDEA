import { useId, useState } from "react";
import { Button } from "@/ui/button";
import { InfoIcon } from "@/ui/icons";
import { Popover, PopoverContent, PopoverDescription, PopoverTrigger } from "@/ui/popover";

/** A field's explanation remains operable independently of its disabled input. */
export function InfoTip({ label, content }: { label: string; content: string }) {
  const descriptionId = useId();
  const triggerId = useId();
  const [open, setOpen] = useState(false);
  const [pinned, setPinned] = useState(false);
  return (
    <Popover
      open={open}
      triggerId={triggerId}
      onOpenChange={(nextOpen, details) => {
        if (details.reason === "trigger-press") {
          // A click always pins a hover-open explanation, even after Base UI's
          // patient-click threshold. A second activation closes it.
          const nextPinned = !pinned;
          if (nextOpen !== nextPinned) details.cancel();
          setPinned(nextPinned);
          setOpen(nextPinned);
        } else if (details.reason === "trigger-hover" && pinned) {
          details.cancel();
        } else {
          setPinned(false);
          setOpen(nextOpen);
        }
      }}
    >
      <PopoverTrigger
        id={triggerId}
        openOnHover
        delay={500}
        closeDelay={0}
        render={<Button type="button" variant="ghost" size="icon-xs" active={open} />}
        aria-label={label}
        aria-describedby={descriptionId}
      >
        <InfoIcon className="size-4" />
      </PopoverTrigger>
      <span id={descriptionId} className="sr-only">
        {content}
      </span>
      <PopoverContent
        aria-label={label}
        initialFocus={false}
        className="max-w-[calc(100vw-16px)] whitespace-pre-wrap break-words"
      >
        <PopoverDescription>{content}</PopoverDescription>
      </PopoverContent>
    </Popover>
  );
}
