import { AlertTriangle } from "lucide-react";
import { useState } from "react";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { getBufferById } from "@/features/editor/utils/buffer-index";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";

interface ExternalConflictBannerProps {
  bufferId: string;
}

/** Presents the explicit IDEA-style choice when disk and live editor text diverge. */
export function ExternalConflictBanner({ bufferId }: ExternalConflictBannerProps) {
  const { t } = useTranslation();
  const [resolving, setResolving] = useState(false);
  const hasConflict = useBufferStore((state) => {
    const buffer = getBufferById(state.buffers, bufferId);
    return buffer?.type === "editor" && buffer.documentLifecycle?.status === "conflict";
  });
  const resolveExternalConflict = useBufferStore.use.actions().resolveExternalConflict;

  if (!hasConflict) return null;

  const resolve = async (resolution: "keepEditor" | "loadDisk") => {
    setResolving(true);
    try {
      await resolveExternalConflict(bufferId, resolution);
    } finally {
      setResolving(false);
    }
  };

  return (
    <div
      className="flex min-h-10 items-center gap-2 border-b border-warning/35 bg-warning/10 px-3 text-xs text-foreground"
      data-testid="editor-external-conflict-banner"
      role="alert"
    >
      <AlertTriangle aria-hidden="true" className="size-4 shrink-0 text-warning" />
      <span className="min-w-0 flex-1">{t("editor.externalConflict")}</span>
      <Button
        disabled={resolving}
        onClick={() => void resolve("keepEditor")}
        size="xs"
        variant="default"
      >
        {t("editor.keepEditorVersion")}
      </Button>
      <Button
        disabled={resolving}
        onClick={() => void resolve("loadDisk")}
        size="xs"
        variant="danger"
      >
        {t("editor.loadDiskVersion")}
      </Button>
    </div>
  );
}
