import { ColumnsIcon as Columns2, EyeIcon, PencilIcon } from "@/ui/icons";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import { isMarkdownEditorBuffer } from "@/features/editor/markdown/previewable";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { getBufferById } from "@/features/editor/utils/buffer-index";
import type { MarkdownViewMode } from "@/features/panes/types/pane-content.types";

const MARKDOWN_VIEW_MODES: readonly MarkdownViewMode[] = ["source", "split", "preview"];

const MODE_ICONS: Record<MarkdownViewMode, typeof PencilIcon> = {
  source: PencilIcon,
  split: Columns2,
  preview: EyeIcon,
};

const MODE_LABEL_KEYS: Record<MarkdownViewMode, string> = {
  source: "editor.markdownSourceView",
  split: "editor.markdownSplitView",
  preview: "editor.markdownPreviewView",
};

interface MarkdownModePickerProps {
  bufferId?: string;
}

/**
 * Editor / split / preview switcher for Markdown editor buffers. Renders
 * nothing for other buffer types; mirrors the macOS markdown mode picker.
 */
export function MarkdownModePicker({ bufferId }: MarkdownModePickerProps) {
  const { t } = useTranslation();
  const setMarkdownViewMode = useBufferStore.use.actions().setMarkdownViewMode;

  const resolvedBufferId = useBufferStore((state) => bufferId ?? state.activeBufferId);
  const currentMode = useBufferStore((state) => {
    const buffer = getBufferById(state.buffers, bufferId ?? state.activeBufferId);
    if (!isMarkdownEditorBuffer(buffer)) return null;
    return buffer.markdownViewMode ?? "source";
  });

  if (!resolvedBufferId || !currentMode) return null;

  return (
    <div
      className="flex items-center gap-0.5"
      role="group"
      aria-label={t("editor.markdownViewModes")}
    >
      {MARKDOWN_VIEW_MODES.map((mode) => {
        const IconComponent = MODE_ICONS[mode];
        const modeLabel = t(MODE_LABEL_KEYS[mode]);
        return (
          <Button
            key={mode}
            variant="ghost"
            size="icon-xs"
            className="rounded text-subtle-foreground"
            onClick={() => setMarkdownViewMode(resolvedBufferId, mode)}
            active={currentMode === mode}
            tooltip={modeLabel}
            tooltipSide="bottom"
            aria-label={modeLabel}
            aria-pressed={currentMode === mode}
          >
            <IconComponent />
          </Button>
        );
      })}
    </div>
  );
}
