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
import { useActiveWorkspaceId } from "@/features/workspace/stores/create-workspace-scoped-store";
import { workspaceScopeMatchesRoot } from "@/features/workspace/types/workspace-launch-scope";
import { getDirName } from "@/utils/path-helpers";

interface UseLspIntegrationOptions {
  enabled?: boolean;
  filePath: string | undefined;
  contentRevision?: number;
}

type LspDocumentOwnerState =
  | { phase: "scheduled" }
  | { phase: "starting"; task: Promise<void> }
  | { phase: "attached"; attachmentId: string }
  | { phase: "open"; attachmentId: string }
  | { phase: "stopping"; task: Promise<void>; attachmentId?: string }
  | { phase: "stopped" }
  | { phase: "failed"; error: unknown };

type DocumentChangeOwnerState =
  | { phase: "idle"; completion: Promise<void> }
  | {
      phase: "scheduled";
      timer: ReturnType<typeof setTimeout>;
      completion: Promise<void>;
    }
  | { phase: "flushing"; completion: Promise<void> };

interface LspDocumentOwner {
  // One record owns every asynchronous resource for one editor attachment.
  state: LspDocumentOwnerState;
  version: number;
  changes: DocumentChangeOwnerState;
}

const DOCUMENT_CHANGE_DEBOUNCE_MS = 75;

function documentTextForPath(filePath: string): string {
  return getSourceEditorBufferByPath(useBufferStore.getState().buffers, filePath)?.content ?? "";
}

function isTerminalOwnerState(state: LspDocumentOwnerState): boolean {
  return state.phase === "stopped" || state.phase === "failed";
}

function attachmentIdForOwner(state: LspDocumentOwnerState): string | undefined {
  return state.phase === "attached" || state.phase === "open" || state.phase === "stopping"
    ? state.attachmentId
    : undefined;
}

export const useLspIntegration = ({
  enabled = true,
  filePath,
  contentRevision = 0,
}: UseLspIntegrationOptions) => {
  const lspClient = useMemo(() => LspClient.getInstance(), []);
  const workspaceId = useActiveWorkspaceId();
  const rootFolderPath = useFileSystemStore((state) => state.rootFolderPath);
  const installedExtensions = useExtensionStore.use.installedExtensions();
  const activeFilePath = enabled ? filePath : undefined;
  const isLspSupported = useMemo(
    () => isEditorLspSupported(activeFilePath),
    [activeFilePath, installedExtensions],
  );
  const lastSyncedRevisionRef = useRef(contentRevision);
  const documentOwnersRef = useRef<Map<string, LspDocumentOwner>>(new Map());

  useEffect(() => {
    if (!enabled || !filePath || !isLspSupported) return;

    const workspacePath = rootFolderPath || getDirName(filePath);
    if (!workspacePath) {
      logger.warn("LspIntegration", `Could not determine workspace path for ${filePath}`);
      return;
    }
    const scope = { workspaceId, root: workspacePath };
    if (
      rootFolderPath &&
      !workspaceScopeMatchesRoot(
        scope,
        useFileSystemStore.getStore(workspaceId).getState().rootFolderPath,
      )
    ) {
      logger.warn("LspIntegration", `Ignoring stale workspace scope for ${filePath}`);
      return;
    }

    const existingOwner = documentOwnersRef.current.get(filePath);
    const owner: LspDocumentOwner =
      existingOwner && !isTerminalOwnerState(existingOwner.state)
        ? existingOwner
        : {
            state: { phase: "scheduled" },
            version: 1,
            changes: { phase: "idle", completion: Promise.resolve() },
          };
    documentOwnersRef.current.set(filePath, owner);

    const cleanupDocument = () => {
      const isStillOpen = Boolean(
        getSourceEditorBufferByPath(useBufferStore.getState().buffers, filePath),
      );
      if (isStillOpen) return;

      if (owner.state.phase === "stopping" || owner.state.phase === "stopped") return;
      const previousState = owner.state;
      const initializationTask = previousState.phase === "starting" ? previousState.task : null;
      const attachmentId = attachmentIdForOwner(previousState);
      const changeCompletion = owner.changes.completion;
      if (owner.changes.phase === "scheduled") clearTimeout(owner.changes.timer);
      owner.changes = { phase: "idle", completion: changeCompletion };
      const stopTask = (async () => {
        await initializationTask?.catch(() => undefined);
        await changeCompletion;
        if (attachmentId) {
          try {
            await lspClient.notifyDocumentClose(filePath, attachmentId);
          } catch (error) {
            logger.error("LspIntegration", `Failed to close LSP document ${filePath}`, error);
          }
          try {
            await lspClient.stopForFile(filePath, attachmentId);
          } catch (error) {
            logger.error("LspIntegration", `Failed to stop LSP attachment ${filePath}`, error);
          }
        }
        owner.state = { phase: "stopped" };
        if (documentOwnersRef.current.get(filePath) === owner) {
          documentOwnersRef.current.delete(filePath);
        }
      })();
      owner.state = { phase: "stopping", task: stopTask, attachmentId };
      void stopTask;
    };

    if (existingOwner && !isTerminalOwnerState(existingOwner.state)) {
      return cleanupDocument;
    }

    const initializeLsp = async () => {
      try {
        logger.debug("LspIntegration", `Starting LSP for ${filePath} in ${workspacePath}`);
        const attachment = await lspClient.startForFile(filePath, scope);
        if (attachment.kind !== "attached") {
          owner.state = { phase: "stopped" };
          if (documentOwnersRef.current.get(filePath) === owner) {
            documentOwnersRef.current.delete(filePath);
          }
          return;
        }
        const { attachmentId } = attachment;
        if (documentOwnersRef.current.get(filePath) !== owner || owner.state.phase !== "starting") {
          await lspClient.stopForFile(filePath, attachmentId);
          return;
        }
        owner.state = { phase: "attached", attachmentId };

        const text = documentTextForPath(filePath);
        await lspClient.notifyDocumentOpen(filePath, text, attachmentId);
        if (documentOwnersRef.current.get(filePath) !== owner || owner.state.phase !== "attached") {
          await lspClient.notifyDocumentClose(filePath, attachmentId);
          await lspClient.stopForFile(filePath, attachmentId);
          return;
        }
        owner.state = { phase: "open", attachmentId };
        logger.debug("LspIntegration", `LSP started and document opened for ${filePath}`);
      } catch (error) {
        if (owner.state.phase !== "stopping" && owner.state.phase !== "stopped") {
          owner.state = { phase: "failed", error };
        }
        logger.error("LspIntegration", `LSP initialization failed for ${filePath}`, error);
      }
    };

    const cancelInitialization = deferUntilAfterNextPaint(() => {
      const task = Promise.resolve().then(initializeLsp);
      owner.state = { phase: "starting", task };
      void task;
    });

    return () => {
      cancelInitialization();
      cleanupDocument();
    };
  }, [enabled, filePath, isLspSupported, lspClient, rootFolderPath, workspaceId]);

  useEffect(() => {
    if (!enabled || !filePath || !isLspSupported) return;

    const flushDocumentChange = (preferIncremental: boolean) => {
      const owner = documentOwnersRef.current.get(filePath);
      if (owner?.state.phase !== "open") return;

      const previousCompletion = owner.changes.completion;
      const completion = previousCompletion.then(async () => {
        if (owner.state.phase !== "open") return;
        const contentChanges = takeLspDocumentChanges(filePath);
        const newVersion = owner.version + 1;
        try {
          if (preferIncremental && contentChanges.length > 0) {
            // Core validates a multi-change batch and falls back to the full
            // text when ranges overlap or cannot be replayed safely.
            await lspClient.notifyDocumentChange(
              filePath,
              documentTextForPath(filePath),
              newVersion,
              contentChanges,
            );
          } else {
            await lspClient.notifyDocumentChange(
              filePath,
              documentTextForPath(filePath),
              newVersion,
            );
          }
          if (owner.state.phase === "open") {
            owner.version = newVersion;
            lastSyncedRevisionRef.current = contentRevision;
          }
        } catch (error) {
          logger.error("LspIntegration", `LSP document change failed for ${filePath}`, error);
        }
      });
      owner.changes = { phase: "flushing", completion };
      void completion.finally(() => {
        if (owner.changes.phase === "flushing" && owner.changes.completion === completion) {
          owner.changes = { phase: "idle", completion };
        }
      });
    };

    const scheduleFlush = (preferIncremental: boolean) => {
      const owner = documentOwnersRef.current.get(filePath);
      if (!owner) return;
      if (owner.changes.phase === "scheduled") clearTimeout(owner.changes.timer);
      const completion = owner.changes.completion;
      const timer = setTimeout(() => {
        if (owner.changes.phase !== "scheduled" || owner.changes.timer !== timer) return;
        owner.changes = { phase: "idle", completion };
        flushDocumentChange(preferIncremental);
      }, DOCUMENT_CHANGE_DEBOUNCE_MS);
      owner.changes = { phase: "scheduled", timer, completion };
    };

    const unsubscribe = subscribeLspDocumentChanges((changedPath) => {
      if (changedPath !== filePath) return;
      scheduleFlush(true);
    });

    if (hasLspDocumentChanges(filePath)) {
      scheduleFlush(true);
    } else if (
      documentOwnersRef.current.get(filePath)?.state.phase === "open" &&
      contentRevision !== lastSyncedRevisionRef.current
    ) {
      scheduleFlush(false);
    }

    return () => {
      unsubscribe();
      const owner = documentOwnersRef.current.get(filePath);
      if (owner?.changes.phase === "scheduled") {
        clearTimeout(owner.changes.timer);
        owner.changes = { phase: "idle", completion: owner.changes.completion };
      }
    };
  }, [contentRevision, enabled, filePath, isLspSupported, lspClient]);
};
