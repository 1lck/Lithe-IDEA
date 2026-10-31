import { useEffect, useMemo, useRef, useSyncExternalStore } from "react";
import { useExtensionStore } from "@/extensions/registry/extension-store";
import { deferUntilAfterNextPaint } from "@/features/editor/lsp/deferred-lsp-work";
import {
  isEditorLspSupported,
  resolveEditorLspSupport,
} from "@/features/editor/lsp/built-in-language-support";
import {
  declarativeLanguageSupportRevision,
  cachedDeclarativeLanguageOwner,
  subscribeDeclarativeLanguageSupport,
} from "@/features/editor/lsp/declarative-language-support";
import { LspClient } from "@/features/editor/lsp/lsp-client";
import {
  hasLspDocumentChanges,
  registerLspDocumentChangeFlusher,
  subscribeLspDocumentChanges,
  takeLspDocumentChanges,
} from "@/features/editor/lsp/pending-document-changes";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { getSourceEditorBufferByPath } from "@/features/editor/utils/buffer-index";
import { logger } from "@/features/editor/utils/logger";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import {
  useActiveWorkspaceId,
  useWorkspaceStoreScopeId,
} from "@/features/workspace/stores/create-workspace-scoped-store";
import {
  workspaceScopeMatchesRoot,
  workspaceScopesMatch,
  type WorkspaceLaunchScope,
} from "@/features/workspace/types/workspace-launch-scope";
import { getDirName } from "@/utils/path-helpers";

interface UseLspIntegrationOptions {
  enabled?: boolean;
  filePath: string | undefined;
  bufferId?: string;
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
  attachmentId: string;
  bufferId: string | undefined;
  scope: WorkspaceLaunchScope;
  declarativeOwner: ReturnType<typeof cachedDeclarativeLanguageOwner>;
  state: LspDocumentOwnerState;
  changes: DocumentChangeOwnerState;
}

const DOCUMENT_CHANGE_DEBOUNCE_MS = 75;

function documentTextForPath(filePath: string, workspaceId: string): string {
  const buffers = useBufferStore.getStore(workspaceId).getState().buffers;
  return getSourceEditorBufferByPath(buffers, filePath)?.content ?? "";
}

function isTerminalOwnerState(state: LspDocumentOwnerState): boolean {
  return state.phase === "stopped" || state.phase === "failed";
}

function isReleasingOwnerState(state: LspDocumentOwnerState): boolean {
  return state.phase === "stopping" || state.phase === "stopped";
}

export const useLspIntegration = ({
  enabled = true,
  filePath,
  bufferId,
  contentRevision = 0,
}: UseLspIntegrationOptions) => {
  const lspClient = useMemo(() => LspClient.getInstance(), []);
  const activeWorkspaceId = useActiveWorkspaceId();
  const workspaceId = useWorkspaceStoreScopeId() ?? activeWorkspaceId;
  const rootFolderPath = useFileSystemStore((state) => state.rootFolderPath);
  const installedExtensions = useExtensionStore.use.installedExtensions();
  const activeFilePath = enabled ? filePath : undefined;
  const declarativeRevision = useSyncExternalStore(
    subscribeDeclarativeLanguageSupport,
    declarativeLanguageSupportRevision,
    declarativeLanguageSupportRevision,
  );
  const isLspSupported = useMemo(
    () => isEditorLspSupported(activeFilePath),
    [activeFilePath, installedExtensions, declarativeRevision],
  );
  const declarativeOwner = useMemo(
    () => activeFilePath ? cachedDeclarativeLanguageOwner(activeFilePath) : null,
    [activeFilePath, declarativeRevision],
  );
  const lastSyncedRevisionRef = useRef(contentRevision);
  const documentOwnersRef = useRef<Map<string, LspDocumentOwner>>(new Map());

  useEffect(() => {
    if (!activeFilePath || isLspSupported) return;
    // Worker and built-in admission stay synchronous. Only unclaimed local
    // files ask the native catalog, which performs no launch or tool probe.
    void resolveEditorLspSupport(activeFilePath).catch((error: unknown) => {
      logger.warn("LspIntegration", "Could not resolve declarative language ownership", error);
    });
  }, [activeFilePath, installedExtensions, isLspSupported, declarativeRevision]);

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

    const previousOwner = documentOwnersRef.current.get(filePath);
    const existingOwner = previousOwner &&
      previousOwner.state.phase !== "stopping" &&
      !isTerminalOwnerState(previousOwner.state) &&
      previousOwner.bufferId === bufferId &&
      previousOwner.declarativeOwner === declarativeOwner &&
      workspaceScopesMatch(previousOwner.scope, scope) ? previousOwner : undefined;
    const owner: LspDocumentOwner = existingOwner ?? {
      attachmentId: crypto.randomUUID(), bufferId, scope, declarativeOwner,
      state: { phase: "scheduled" },
      changes: { phase: "idle", completion: Promise.resolve() },
    };
    documentOwnersRef.current.set(filePath, owner);

    const cleanupDocument = () => {
      // The deferred callback was cancelled by this effect's cleanup. There
      // is no attachment to retain, even if the buffer itself remains open.
      if (owner.state.phase === "scheduled") {
        owner.state = { phase: "stopped" };
        if (documentOwnersRef.current.get(filePath) === owner) documentOwnersRef.current.delete(filePath);
        return;
      }
      const buffer = getSourceEditorBufferByPath(
        useBufferStore.getStore(workspaceId).getState().buffers, filePath,
      );
      const isStillOpen = buffer && (!bufferId || buffer.id === bufferId);
      // An open buffer can retain an attachment across view changes, but a
      // revoked plugin must release it even while its document stays open.
      if (isStillOpen && isEditorLspSupported(filePath) &&
          cachedDeclarativeLanguageOwner(filePath) === declarativeOwner) return;

      if (owner.state.phase === "stopping" || owner.state.phase === "stopped") return;
      const previousState = owner.state;
      const initializationTask = previousState.phase === "starting" ? previousState.task : null;
      const attachmentId = owner.attachmentId;
      const changeCompletion = owner.changes.completion;
      if (owner.changes.phase === "scheduled") clearTimeout(owner.changes.timer);
      owner.changes = { phase: "idle", completion: changeCompletion };
      // Revoke the pending identity synchronously, before a reopened editor
      // can start. Native teardown still drains its actual initialization.
      const pendingStop = previousState.phase === "starting"
        ? lspClient.stopForFile(filePath, attachmentId) : null;
      // Teardown can fail before initialization settles. Observe that promise
      // immediately; the awaited cleanup below still reports the same error.
      void pendingStop?.catch(() => undefined);
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
            await (pendingStop ?? lspClient.stopForFile(filePath, attachmentId));
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

    if (existingOwner) {
      return cleanupDocument;
    }

    const initializeLsp = async () => {
      if (owner.state.phase !== "starting" || documentOwnersRef.current.get(filePath) !== owner) return;
      try {
        logger.debug("LspIntegration", `Starting LSP for ${filePath} in ${workspacePath}`);
        const attachment = await lspClient.startForFile(filePath, scope, "attach", owner.attachmentId);
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

        const text = documentTextForPath(filePath, workspaceId);
        await lspClient.notifyDocumentOpen(filePath, text, attachmentId);
        if (documentOwnersRef.current.get(filePath) !== owner || owner.state.phase !== "attached") {
          await lspClient.notifyDocumentClose(filePath, attachmentId);
          await lspClient.stopForFile(filePath, attachmentId);
          return;
        }
        owner.state = { phase: "open", attachmentId };
        logger.debug("LspIntegration", `LSP started and document opened for ${filePath}`);
      } catch (error) {
        if (!isReleasingOwnerState(owner.state)) {
          owner.state = { phase: "failed", error };
        }
        logger.error("LspIntegration", `LSP initialization failed for ${filePath}`, error);
      }
    };

    const cancelInitialization = deferUntilAfterNextPaint(() => {
      if (owner.state.phase !== "scheduled" || documentOwnersRef.current.get(filePath) !== owner) return;
      const task = Promise.resolve().then(initializeLsp);
      owner.state = { phase: "starting", task };
      void task;
    });

    return () => {
      cancelInitialization();
      cleanupDocument();
    };
  }, [enabled, filePath, bufferId, isLspSupported, declarativeOwner, lspClient, rootFolderPath, workspaceId]);

  useEffect(() => {
    if (!enabled || !filePath || !isLspSupported) return;

    // A semantic request may already be waiting behind a change when this
    // view becomes hidden. Retaining the document attachment does not retain
    // this view's right to consume changes or send its captured workspace text.
    let active = true;
    const flushDocumentChange = (preferIncremental: boolean) => {
      if (!active) return;
      const owner = documentOwnersRef.current.get(filePath);
      if (owner?.state.phase !== "open") return;

      const previousCompletion = owner.changes.completion;
      const completion = previousCompletion.then(async () => {
        if (!active || owner.state.phase !== "open" || documentOwnersRef.current.get(filePath) !== owner) return;
        const contentChanges = takeLspDocumentChanges(filePath);
        try {
          if (preferIncremental && contentChanges.length > 0) {
            await lspClient.synchronizeDocument(
              filePath,
              documentTextForPath(filePath, workspaceId),
              contentChanges,
            );
          } else {
            await lspClient.synchronizeDocument(
              filePath, documentTextForPath(filePath, workspaceId),
            );
          }
          if (owner.state.phase === "open") {
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

    // Sends whatever the debounce is still holding and waits for the in-flight
    // send, so a request issued from the same keystroke is answered against the
    // text the editor actually shows. Bounded so continuous typing cannot
    // starve the request.
    const flushBeforeRequest = async (): Promise<void> => {
      for (let attempt = 0; attempt < 3; attempt += 1) {
        if (!active) return;
        const owner = documentOwnersRef.current.get(filePath);
        if (owner?.state.phase !== "open") return;
        if (owner.changes.phase === "scheduled") {
          clearTimeout(owner.changes.timer);
          owner.changes = { phase: "idle", completion: owner.changes.completion };
        }
        if (!hasLspDocumentChanges(filePath)) {
          await documentOwnersRef.current.get(filePath)?.changes.completion;
          return;
        }
        if (owner.changes.phase === "idle") {
          flushDocumentChange(true);
        }
        await documentOwnersRef.current.get(filePath)?.changes.completion;
      }
    };
    const unregisterFlusher = registerLspDocumentChangeFlusher(filePath, flushBeforeRequest);

    if (hasLspDocumentChanges(filePath)) {
      scheduleFlush(true);
    } else if (
      documentOwnersRef.current.get(filePath)?.state.phase === "open" &&
      contentRevision !== lastSyncedRevisionRef.current
    ) {
      scheduleFlush(false);
    }

    return () => {
      active = false;
      unsubscribe();
      unregisterFlusher();
      const owner = documentOwnersRef.current.get(filePath);
      if (owner?.changes.phase === "scheduled") {
        clearTimeout(owner.changes.timer);
        owner.changes = { phase: "idle", completion: owner.changes.completion };
      }
    };
  }, [contentRevision, enabled, filePath, bufferId, isLspSupported, declarativeOwner, lspClient, workspaceId]);
};
