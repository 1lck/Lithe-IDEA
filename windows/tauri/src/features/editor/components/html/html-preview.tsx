import { useEffect, useRef, useState } from "react";
import { useShallow } from "zustand/react/shallow";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { getBufferById, getBufferByPath } from "@/features/editor/utils/buffer-index";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { isLocalDocumentPath } from "@/platform/document-files";
import { invoke } from "@/platform/tauri-core";
import { hasTextContent } from "@/features/panes/types/pane-content.types";
import { useTranslation } from "@/i18n/locale-provider";
import { ArrowSquareOutIcon as ExternalLink } from "@/ui/icons";
import { Button } from "@/ui/button";
import { Empty, EmptyDescription } from "@/ui/empty";
import { toast } from "sonner";
import { buildHtmlPreviewDocument } from "./html-preview-document";

export function HtmlPreview() {
  const { t } = useTranslation();
  const { hasSourceBuffer, sourceContent, sourcePath } = useBufferStore(
    useShallow((state) => {
      const activeBuffer = getBufferById(state.buffers, state.activeBufferId);
      const sourceBuffer =
        activeBuffer?.type === "htmlPreview"
          ? (getBufferByPath(state.buffers, activeBuffer.sourceFilePath) ?? activeBuffer)
          : activeBuffer;

      return {
        hasSourceBuffer: Boolean(sourceBuffer),
        sourceContent: sourceBuffer && hasTextContent(sourceBuffer) ? sourceBuffer.content : "",
        sourcePath: sourceBuffer?.path,
      };
    }),
  );
  const rootFolderPath = useFileSystemStore.use.rootFolderPath?.();

  const [iframeContent, setIframeContent] = useState("");
  const containerRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    setIframeContent(buildHtmlPreviewDocument(sourceContent, { sourcePath, rootFolderPath }));
  }, [sourceContent, sourcePath, rootFolderPath]);

  const canOpenInBrowser = Boolean(sourcePath && isLocalDocumentPath(sourcePath));

  const handleOpenInBrowser = async () => {
    if (!sourcePath || !canOpenInBrowser) return;

    try {
      await invoke("open_file_external", { path: sourcePath });
    } catch (error) {
      console.error("Failed to open HTML in browser:", error);
      toast.error(t("editor.openHtmlInBrowserFailed"));
    }
  };

  if (!hasSourceBuffer) {
    return (
      <Empty className="h-full rounded-none">
        <EmptyDescription>{t("htmlPreview.noActiveBuffer")}</EmptyDescription>
      </Empty>
    );
  }

  return (
    <div ref={containerRef} className="html-preview relative size-full bg-white">
      {canOpenInBrowser ? (
        <div className="absolute top-2 right-2 z-10 rounded-md border border-border/70 bg-background/90 p-0.5 shadow-sm backdrop-blur-sm">
          <Button
            variant="ghost"
            size="icon-xs"
            tooltip={t("editor.openHtmlInBrowser")}
            tooltipSide="bottom"
            onClick={() => void handleOpenInBrowser()}
          >
            <ExternalLink />
          </Button>
        </div>
      ) : null}
      <iframe
        title={t("htmlPreview.title")}
        srcDoc={iframeContent}
        className="size-full border-none"
        sandbox="allow-scripts allow-same-origin allow-forms allow-popups allow-modals"
      />
    </div>
  );
}
