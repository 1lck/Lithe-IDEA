import { forwardRef } from "react";
import type { IconProps } from "@/ui/icons";

export const RunIcon = forwardRef<SVGSVGElement, IconProps>(function RunIcon(
  { size = "1em", className, title, ...props },
  ref,
) {
  return (
    <svg
      ref={ref}
      width={size}
      height={size}
      viewBox="0 0 16 16"
      fill="none"
      className={className}
      aria-hidden={title ? undefined : true}
      {...props}
    >
      {title ? <title>{title}</title> : null}
      <path
        d="M5.15 3.35 12.7 8 5.15 12.65Z"
        stroke="currentColor"
        strokeWidth="1.25"
        strokeLinejoin="round"
        strokeLinecap="round"
      />
    </svg>
  );
});

export function JavaCupIcon({ className }: { className?: string }) {
  return (
    <svg viewBox="0 0 16 16" width="14" height="14" fill="none" className={className} aria-hidden>
      <path
        d="M3.5 5.5h7.25c.97 0 1.75.78 1.75 1.75S11.72 9 10.75 9H10.5"
        stroke="currentColor"
        strokeWidth="1.15"
        strokeLinecap="round"
      />
      <path
        d="M3.75 5.5h6.5v4.25a2.75 2.75 0 0 1-2.75 2.75h-1A2.75 2.75 0 0 1 3.75 9.75V5.5Z"
        stroke="currentColor"
        strokeWidth="1.15"
      />
      <path d="M4.25 13.25h5.5" stroke="currentColor" strokeWidth="1.15" strokeLinecap="round" />
    </svg>
  );
}
