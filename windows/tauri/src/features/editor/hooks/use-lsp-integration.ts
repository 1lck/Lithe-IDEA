import { useEffect, useMemo, useRef } from "react";
import { useExtensionStore } from "@/extensions/registry/extension-store";
import { deferUntilAfterNextPaint } from "@/features/editor/lsp/deferred-lsp-work";
import { isEditorLspSupported } from "@/features/editor/lsp/built-in-language-support";
import { LspClient } from "@/features/editor/lsp/lsp-client";
import {
  hasLspDocumentChanges,
  subscribeLspDocumentChanges,
  takeLspDocumentChanges,
} from "@/features/editor/lsp/pending-document-changes";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { getSourceEditorBufferByPath } from "@/features/editor/utils/buffer-index";
import { logger } from "@/features/editor/utils/logger";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { getDirName } from "@/utils/path-helpers";

interface UseLspIntegrationOptions {
  enabled?: boolean;
  filePath: string | undefined;
  contentRevision?: number;
}

const DOCUMENT_CHANGE_DEBOUNCE_MS = 75;

function documentTextForPath(filePath: string): string {
  return getSourceEditorBufferByPath(useBufferStore.getState().buffers, filePath)?.content ?? "";
}

export const useLspIntegration = ({
  enabled = true,
  filePath,
  contentRevision = 0,
}: UseLspIntegrationOptions) => {
  const lspClient = useMemo(() => LspClient.getInstance(), []);
  const rootFolderPath = useFileSystemStore((state) => state.rootFolderPath);
  const installedExtensions = useExtensionStore.use.installedExtensions();
  const activeFilePath = enabled ? filePath : undefined;
  const isLspSupported = useMemo(
    () => isEditorLspSupported(activeFilePath),
    [activeFilePath, installedExtensions],
  );
  const documentChangeTimerRef = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  const documentVersionsRef = useRef<Map<string, number>>(new Map());
  const lastSyncedRevisionRef = useRef(contentRevision);
  const openedDocumentsRef = useRef<Set<string>>(new Set());

  useEffect(() => {
    if (!enabled || !filePath || !isLspSupported) return;

    const workspacePath = rootFolderPath || getDirName(filePath);
    if (!workspacePath) {
      console.warn("LSP: Could not determine workspace path for", filePath);
      return;
    }

    const cleanupDocument = () => {
      const isStillOpen = Boolean(
        getSourceEditorBufferByPath(useBufferStore.getState().buffers, filePath),
      );
      if (isStillOpen) return;

      if (openedDocumentsRef.current.has(filePath)) {
        lspClient.notifyDocumentClose(filePath).catch((error) => {
          console.error("LSP document close error:", error);
        });
        lspClient.stopForFile(filePath).catch((error) => {
          console.error("LSP stop for file error:", error);
        });
      }

      documentVersionsRef.current.delete(filePath);
      openedDocumentsRef.current.delete(filePath);
    };

    if (openedDocumentsRef.current.has(filePath)) {
      return cleanupDocument;
    }

    const initializeLsp = async () => {
      try {
        logger.debug("LspIntegration", `Starting LSP for ${filePath} in ${workspacePath}`);
        documentVersionsRef.current.set(filePath, 1);
        const started = await lspClient.startForFile(filePath, workspacePath);
        if (!started) return;

        const text = documentTextForPath(filePath);
        await lspClient.notifyDocumentOpen(filePath, text);
        openedDocumentsRef.current.add(filePath);
        logger.debug("LspIntegration", `LSP started and document opened for ${filePath}`);
      } catch (error) {
        console.error("LSP initialization error:", error);
      }
    };

    const cancelInitialization = deferUntilAfterNextPaint(() => {
      void initializeLsp();
    });

    return () => {
      cancelInitialization();
      cleanupDocument();
    };
  }, [enabled, filePath, isLspSupported, lspClient, rootFolderPath]);

  useEffect(() => {
    if (!enabled || !filePath || !isLspSupported) return;

    const flushDocumentChange = (preferIncremental: boolean) => {
      if (!openedDocumentsRef.current.has(filePath)) return;

      const contentChanges = takeLspDocumentChanges(filePath);
      const currentVersion = documentVersionsRef.current.get(filePath) || 1;
      const newVersion = currentVersion + 1;
      documentVersionsRef.current.set(filePath, newVersion);
      lastSyncedRevisionRef.current = contentRevision;

      const notify =
        preferIncremental && contentChanges.length > 0
          ? // Always include the latest full text so Core can fall back to a
            // full-document didChange when a multi-change batch is unsafe to
            // replay incrementally (overlap / missing ranges).
            lspClient.notifyDocumentChange(
              filePath,
              documentTextForPath(filePath),
              newVersion,
              contentChanges,
            )
          : lspClient.notifyDocumentChange(filePath, documentTextForPath(filePath), newVersion);

      notify.catch((error) => {
        console.error("LSP document change error:", error);
      });
    };

    const scheduleFlush = (preferIncremental: boolean) => {
      if (documentChangeTimerRef.current) {
        clearTimeout(documentChangeTimerRef.current);
      }
      documentChangeTimerRef.current = setTimeout(() => {
        documentChangeTimerRef.current = undefined;
        flushDocumentChange(preferIncremental);
      }, DOCUMENT_CHANGE_DEBOUNCE_MS);
    };

    const unsubscribe = subscribeLspDocumentChanges((changedPath) => {
      if (changedPath !== filePath) return;
      scheduleFlush(true);
    });

    if (hasLspDocumentChanges(filePath)) {
      scheduleFlush(true);
    } else if (
      openedDocumentsRef.current.has(filePath) &&
      contentRevision !== lastSyncedRevisionRef.current
    ) {
      scheduleFlush(false);
    }

    return () => {
      unsubscribe();
      if (documentChangeTimerRef.current) {
        clearTimeout(documentChangeTimerRef.current);
        documentChangeTimerRef.current = undefined;
      }
    };
  }, [contentRevision, enabled, filePath, isLspSupported, lspClient]);
};
