import type React from "react";
import type { ReactNode } from "react";

interface HorizontalTerminalTabStripProps {
  pinnedTabs: ReactNode;
  regularTabs: ReactNode;
  actions: ReactNode;
  onWheel: (event: React.WheelEvent<HTMLDivElement>) => void;
}

// Pinned and regular tabs share one scroll area so neither group can push the trailing
// new-terminal actions out of view; only the actions stay fixed beside the scrolled tabs.
export function HorizontalTerminalTabStrip({
  pinnedTabs,
  regularTabs,
  actions,
  onWheel,
}: HorizontalTerminalTabStripProps) {
  return (
    <div className="flex min-w-0 flex-1 items-center gap-0.5 overflow-hidden">
      <div
        className="scrollbar-hidden flex min-w-0 flex-initial items-center gap-0.5 overflow-x-auto overflow-y-hidden"
        data-tab-container
        onWheel={onWheel}
      >
        {pinnedTabs ? (
          <div className="flex shrink-0 items-center gap-0.5 pr-0.5" data-pinned-tabs>
            {pinnedTabs}
          </div>
        ) : null}
        {regularTabs}
      </div>
      <div className="flex shrink-0 items-center" data-tab-strip-actions>
        {actions}
      </div>
    </div>
  );
}
