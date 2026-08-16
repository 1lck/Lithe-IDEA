import { useState } from "react";
import { PuzzlePieceIcon } from "@/ui/icons";
import Tooltip from "@/ui/tooltip";

export function PluginActivityRail() {
  const [selected, setSelected] = useState(false);

  return (
    <aside
      aria-label="Plugins"
      className="flex w-9.5 shrink-0 flex-col items-center bg-surface pt-1"
    >
      <Tooltip content="Plugins" side="left">
        <button
          type="button"
          className={`flex size-7.5 items-center justify-center rounded-sm text-subtle-foreground transition-colors hover:bg-accent hover:text-foreground ${
            selected ? "bg-selected text-foreground" : ""
          }`}
          onClick={() => setSelected((value) => !value)}
          aria-pressed={selected}
          aria-label="Plugins"
        >
          <PuzzlePieceIcon className="size-4.5" />
        </button>
      </Tooltip>
    </aside>
  );
}
