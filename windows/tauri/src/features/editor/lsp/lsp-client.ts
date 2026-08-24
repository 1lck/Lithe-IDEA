import {
  getLspSessionSnapshot,
  getLspWorkspaceSessionSnapshot,
  invokeLsp as invoke,
  isLspSemanticCommandSupported,
} from "@/platform/lsp-core-adapter";
import { listen } from "@tauri-apps/api/event";
import type {
  CompletionItem,
  Hover,
  PublishDiagnosticsParams,
} from "vscode-languageserver-protocol";
import {
  convertLSPDiagnostic,
  useDiagnosticsStore,
} from "@/features/diagnostics/stores/diagnostics.store";
import type {
  ApplyDiagnosticCodeActionResult,
  Diagnostic,
  DiagnosticCodeAction,
} from "@/features/diagnostics/types/diagnostics.types";
import { hasTextContent, shouldStartLsp } from "@/features/panes/types/pane-content.types";
import { useBufferStore } from "../stores/buffer.store";
import { logger } from "../utils/logger";
import { normalizePath } from "@/utils/path-helpers";
import { getLanguageDisplayName } from "../utils/language-id";
import {
  isBuiltInLspPath,
  JAVA_LANGUAGE_ID,
  languageIdForEditorFile,
} from "./built-in-language-support";
import { resolvePublishedDiagnosticsFilePath } from "./diagnostics-file-path";
import { resolveEditorLspLaunch } from "./resolve-editor-lsp-launch";
import type { LspSemanticTokensResponse } from "./semantic-token-types";
import {
  normalizeJavaImplementationMarkers,
  type JavaImplementationMarker,
} from "./java-navigation-models";
import { useLspStore } from "./stores/lsp.store";
import {
  lspDocumentRequestArgs,
  lspSessionFilePath,
  normalizeLspDocumentTarget,
  type LspDocumentTargetInput,
} from "./lsp-document-target";
import {
  clearLanguageServerFailure,
  isLanguageServerFailureCoolingDown,
  recordLanguageServerFailure,
} from "./language-server-failure-cooldown";
import { isCanceledLspRequest, normalizeLspError } from "./lsp-request-error";
import {
  applyWorkspaceEdit,
  applyTextEditsToContent,
  filePathFromUri,
  isWorkspaceEdit,
  type LspTextEdit,
  type WorkspaceEdit,
} from "./workspace-edit";
import type { LspAdapterSessionPhase } from "@/platform/lsp-session-lifecycle";

export type LspWorkspaceStartOutcome =
  | { kind: "ready" }
  | { kind: "unsupportedHost" }
  | { kind: "notConfigured" };

export type LspFileAttachmentOutcome =
  | { kind: "attached"; attachmentId: string }
  | { kind: "cancelled"; reason: "superseded" | "unsupportedHost" };

type LanguageServerRepairOutcome =
  | { kind: "repaired" }
  | { kind: "unavailable"; reason: "extensionUnavailable" | "runtimeUnresolved" }
  | { kind: "failed"; error: unknown };

export type LspDocumentAvailability =
  | { phase: "unavailable"; languageId?: string }
  | {
      phase: "preparing";
      languageId?: string;
      workspacePath: string;
      sessionPhase: Exclude<LspAdapterSessionPhase, "ready" | "failed" | "stopped">;
    }
  | {
      phase: "failed";
      languageId?: string;
      workspacePath: string;
      sessionPhase: "failed" | "stopped";
    }
  | {
      phase: "ready";
      languageId?: string;
      workspacePath: string;
      feature: "supported" | "unsupported" | "unknown";
    };

export function isDocumentFeatureAvailable(availability: LspDocumentAvailability): boolean {
  return availability.phase === "ready" && availability.feature === "supported";
}

export interface LspLocation {
  uri: string;
  filePath?: string | null;
  displayPath?: string | null;
  isReadOnly?: boolean;
  range: {
    start: { line: number; character: number };
    end: { line: number; character: number };
  };
}

interface PrepareRenameResult {
  range?: {
    start: { line: number; character: number };
    end: { line: number; character: number };
  };
  placeholder?: string;
  defaultBehavior?: boolean;
  start?: { line: number; character: number };
  end?: { line: number; character: number };
}

type TrackedLspDocument = {
  filePath: string;
  attachmentId: string;
  version: number;
  phase: "open" | "closing";
};

type PendingFileStart = {
  workspacePath: string;
  task: Promise<LspFileAttachmentOutcome>;
};

type LspFileStartIntent = "attach" | "manualRestart";

type LspFileStartAttempt =
  | { kind: "attach"; attachmentId: string }
  | { kind: "manualRestart"; attachmentId: string }
  | { kind: "repairRetry"; attachmentId: string };

type PendingDocumentOpen = {
  attachmentId: string;
  task: Promise<void>;
};

function stringifyLspError(error: unknown): string {
  return normalizeLspError(error).message;
}

function getUserFacingLspErrorMessage(error: unknown): string {
  const normalized = normalizeLspError(error);

  switch (normalized.code) {
    case "tool_not_found":
      return `${normalized.message} Open Extensions and reinstall the language tools.`;
    case "tool_not_executable":
      return `${normalized.message} The installed binary is present but cannot run.`;
    default:
      return normalized.message;
  }
}

function isBenignHoverError(error: unknown): boolean {
  const message = stringifyLspError(error).toLowerCase();
  return (
    message.includes("column is beyond end of line") ||
    message.includes("column is beyond end of file") ||
    message.includes("no lsp client for this file")
  );
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function trackedFileKey(filePath: string): string {
  const normalized = normalizePath(filePath);
  return /^(?:[A-Za-z]:\/|\/\/)/.test(normalized) ? normalized.toLowerCase() : normalized;
}

function getCodeActionEdit(actionPayload: unknown): unknown {
  if (!isRecord(actionPayload)) return null;
  return actionPayload.edit;
}

function hasCodeActionCommand(actionPayload: unknown): boolean {
  return isRecord(actionPayload) && isRecord(actionPayload.command);
}

function withoutWorkspaceEdit(actionPayload: unknown): unknown {
  if (!isRecord(actionPayload)) return actionPayload;

  const { edit: _edit, ...commandPayload } = actionPayload;
  return commandPayload;
}

export class LspClient {
  private static instance: LspClient | null = null;
  private activeLanguageServers = new Set<string>(); // workspace:language format
  private activeLanguages = new Set<string>(); // Track active language IDs for status
  private activeServerFiles = new Map<string, Set<string>>(); // workspace:language -> tracked files
  private workspaceRepresentativeFiles = new Map<string, string>();
  /** workspace:language -> failure timestamp (ms); expired after a short cooldown. */
  private failedLanguageServers = new Map<string, number>();
  private repairLanguageServerPromises = new Map<string, Promise<LanguageServerRepairOutcome>>();
  private fileAttachmentIds = new Map<string, string>();
  private fileStartTasks = new Map<string, PendingFileStart>();
  private workspaceStartTasks = new Map<string, Promise<LspWorkspaceStartOutcome>>();
  private documentOpenTasks = new Map<string, PendingDocumentOpen>();
  private documents = new Map<string, TrackedLspDocument>();

  private constructor() {
    this.setupDiagnosticsListener();
    this.setupCrashListener();
  }

  /**
   * Update the LSP status store with current state
   */
  private updateLspStatus() {
    const { actions } = useLspStore.getState();
    const workspaces = this.getActiveWorkspaces();
    const languages = Array.from(this.activeLanguages);

    if (this.activeLanguageServers.size > 0) {
      actions.updateLspStatus("connected", workspaces, undefined, languages);
    } else {
      actions.updateLspStatus("disconnected", [], undefined, []);
    }
  }

  private isRepairableStartupError(error: unknown): boolean {
    const normalized = normalizeLspError(error);
    return normalized.code === "tool_not_found" || normalized.code === "tool_not_executable";
  }

  private async repairLanguageServerForFile(
    filePath: string,
    languageId: string,
  ): Promise<LanguageServerRepairOutcome> {
    const repairKey = `${filePath}:${languageId}`;
    const existingRepair = this.repairLanguageServerPromises.get(repairKey);
    if (existingRepair) {
      return existingRepair;
    }

    const repairPromise = this.runLanguageServerRepair(filePath, languageId).finally(() => {
      this.repairLanguageServerPromises.delete(repairKey);
    });

    this.repairLanguageServerPromises.set(repairKey, repairPromise);
    return repairPromise;
  }

  private async runLanguageServerRepair(
    filePath: string,
    languageId: string,
  ): Promise<LanguageServerRepairOutcome> {
    try {
      const [
        { useExtensionStore, waitForExtensionStoreInitialization },
        { buildRuntimeManifest, resolveToolPaths },
        { extensionRegistry },
      ] = await Promise.all([
        import("@/extensions/registry/extension-store"),
        import("@/extensions/registry/extension-store-runtime"),
        import("@/extensions/registry/extension-registry"),
      ]);

      await waitForExtensionStoreInitialization();

      const extension = useExtensionStore.getState().actions.getExtensionForFile(filePath);
      if (!extension?.isInstalled || !extension.manifest.lsp) {
        return { kind: "unavailable", reason: "extensionUnavailable" };
      }

      logger.info(
        "LSPClient",
        `Repairing language server tools for ${languageId} (${extension.manifest.id})`,
      );

      const resolvedTools = await resolveToolPaths(languageId, extension.manifest, {
        ensureInstalled: true,
        repairMissing: true,
      });
      const runtimeManifest = buildRuntimeManifest(extension.manifest, resolvedTools.toolPaths);

      useExtensionStore.setState((state) => {
        const availableExtensions = new Map(state.availableExtensions);
        const current = availableExtensions.get(extension.manifest.id);
        if (current) {
          availableExtensions.set(extension.manifest.id, {
            ...current,
            runtimeIssues: resolvedTools.issues,
            isInstalled: true,
            manifest: runtimeManifest.lsp ? runtimeManifest : current.manifest,
          });
        }
        return {
          availableExtensions,
        };
      });

      if (!runtimeManifest.lsp) {
        logger.warn("LSPClient", `Language server repair did not resolve an LSP for ${languageId}`);
        return { kind: "unavailable", reason: "runtimeUnresolved" };
      }

      extensionRegistry.registerExtension(runtimeManifest, {
        isBundled: false,
        isEnabled: true,
        state: "installed",
      });

      return { kind: "repaired" };
    } catch (error) {
      logger.error("LSPClient", "Language server repair failed:", error);
      return { kind: "failed", error };
    }
  }

  private findServerKeyForFile(filePath: string, languageId?: string): string | null {
    const targetKey = trackedFileKey(filePath);
    const tracksFile = (trackedFiles: Set<string>) =>
      Array.from(trackedFiles).some((trackedFile) => trackedFileKey(trackedFile) === targetKey);
    if (languageId) {
      const directMatch = Array.from(this.activeServerFiles.entries()).find(
        ([key, trackedFiles]) => tracksFile(trackedFiles) && key.endsWith(`:${languageId}`),
      );
      if (directMatch) return directMatch[0];
    }

    const fallbackMatch = Array.from(this.activeServerFiles.entries()).find(([, trackedFiles]) =>
      tracksFile(trackedFiles),
    );
    return fallbackMatch?.[0] ?? null;
  }

  private addTrackedFile(serverKey: string, filePath: string) {
    const targetKey = trackedFileKey(filePath);
    for (const [existingKey, trackedFiles] of this.activeServerFiles) {
      if (existingKey === serverKey) continue;
      for (const trackedFile of trackedFiles) {
        if (trackedFileKey(trackedFile) === targetKey) trackedFiles.delete(trackedFile);
      }
      if (trackedFiles.size === 0) {
        this.activeServerFiles.delete(existingKey);
        this.activeLanguageServers.delete(existingKey);
      }
    }
    const trackedFiles = this.activeServerFiles.get(serverKey) ?? new Set<string>();
    for (const trackedFile of trackedFiles) {
      if (trackedFileKey(trackedFile) === targetKey) trackedFiles.delete(trackedFile);
    }
    trackedFiles.add(filePath);
    this.activeServerFiles.set(serverKey, trackedFiles);
  }

  private registerActiveServer(serverKey: string, languageId: string, filePath?: string) {
    this.activeLanguageServers.add(serverKey);
    if (filePath) this.addTrackedFile(serverKey, filePath);
    this.activeLanguages.add(getLanguageDisplayName(languageId));
    this.updateLspStatus();
  }

  private removeTrackedFile(serverKey: string, filePath: string) {
    const trackedFiles = this.activeServerFiles.get(serverKey);
    if (!trackedFiles) return;

    const targetKey = trackedFileKey(filePath);
    for (const trackedFile of trackedFiles) {
      if (trackedFileKey(trackedFile) === targetKey) trackedFiles.delete(trackedFile);
    }
    if (trackedFiles.size === 0) {
      this.activeServerFiles.delete(serverKey);
      return;
    }

    this.activeServerFiles.set(serverKey, trackedFiles);
  }

  private getRepresentativeFilePath(serverKey: string): string | null {
    const trackedFiles = this.activeServerFiles.get(serverKey);
    if (!trackedFiles || trackedFiles.size === 0) {
      return this.workspaceRepresentativeFiles.get(serverKey) ?? null;
    }

    return trackedFiles.values().next().value ?? null;
  }

  private buildServerEntry(serverKey: string): {
    key: string;
    workspacePath: string;
    languageId: string;
    displayName: string;
    filePath: string | null;
  } {
    const { workspacePath, languageId } = this.parseServerKey(serverKey);
    return {
      key: serverKey,
      workspacePath,
      languageId,
      displayName: getLanguageDisplayName(languageId),
      filePath: this.getRepresentativeFilePath(serverKey),
    };
  }

  private parseServerKey(serverKey: string): { workspacePath: string; languageId: string } {
    const separatorIndex = serverKey.lastIndexOf(":");
    if (separatorIndex === -1) {
      return { workspacePath: serverKey, languageId: "" };
    }

    return {
      workspacePath: serverKey.slice(0, separatorIndex),
      languageId: serverKey.slice(separatorIndex + 1),
    };
  }

  getActiveServerEntries(): Array<{
    key: string;
    workspacePath: string;
    languageId: string;
    displayName: string;
    filePath: string | null;
  }> {
    return Array.from(this.activeLanguageServers)
      .map((key) => this.buildServerEntry(key))
      .sort((a, b) => a.displayName.localeCompare(b.displayName));
  }

  getActiveServerEntryForFile(filePath: string, languageId?: string) {
    const serverKey = this.findServerKeyForFile(filePath, languageId);
    return serverKey ? this.buildServerEntry(serverKey) : null;
  }

  isDocumentOpen(filePath: string): boolean {
    return this.documents.get(trackedFileKey(filePath))?.phase === "open";
  }

  static getInstance(): LspClient {
    if (!LspClient.instance) {
      LspClient.instance = new LspClient();
    }
    return LspClient.instance;
  }

  private async setupDiagnosticsListener() {
    try {
      logger.debug("LSPClient", "Setting up diagnostics listener");
      const unlisten = await listen<PublishDiagnosticsParams>("lsp://diagnostics", (event) => {
        try {
          if (!event.payload) {
            logger.error("LSPClient", "No payload in diagnostics event");
            return;
          }

          const { uri, diagnostics } = event.payload;

          if (!uri) {
            logger.error("LSPClient", "No uri in diagnostics payload:", event.payload);
            return;
          }

          logger.debug("LSPClient", `Received diagnostics for ${uri}:`, diagnostics);

          const publishedFilePath = filePathFromUri(uri);
          const sourceBufferPaths = useBufferStore
            .getState()
            .buffers.filter(shouldStartLsp)
            .map((buffer) => buffer.path);
          const filePath = resolvePublishedDiagnosticsFilePath(
            publishedFilePath,
            sourceBufferPaths,
            new Set(
              [...this.documents.values()]
                .filter((document) => document.phase === "open")
                .map((document) => document.filePath),
            ),
          );

          if (!filePath) {
            logger.debug(
              "LSPClient",
              `Ignoring diagnostics for closed document: ${publishedFilePath}`,
            );
            return;
          }

          const publishedVersion = event.payload.version;
          const currentVersion = this.documents.get(trackedFileKey(filePath))?.version;
          if (
            typeof publishedVersion === "number" &&
            typeof currentVersion === "number" &&
            publishedVersion < currentVersion
          ) {
            logger.debug(
              "LSPClient",
              `Ignoring stale diagnostics for ${filePath}: ${publishedVersion} < ${currentVersion}`,
            );
            return;
          }

          // Convert LSP diagnostics to our internal format
          const diagnosticsList = diagnostics || [];
          const convertedDiagnostics = diagnosticsList.map((d) =>
            convertLSPDiagnostic(filePath, d),
          );
          logger.debug(
            "LSPClient",
            `Converted ${convertedDiagnostics.length} diagnostics for ${filePath}`,
          );

          // Update diagnostics store
          const { setDiagnostics } = useDiagnosticsStore.getState().actions;
          setDiagnostics(filePath, convertedDiagnostics, "lsp");

          logger.debug(
            "LSPClient",
            `Updated diagnostics for ${filePath}: ${convertedDiagnostics.length} items`,
          );
        } catch (innerError) {
          logger.error("LSPClient", "Error processing diagnostics event:", innerError);
        }
      });
      logger.debug("LSPClient", "Diagnostics listener setup complete", unlisten);
    } catch (error) {
      logger.error("LSPClient", "Failed to setup diagnostics listener:", error);
    }
  }

  private async setupCrashListener() {
    try {
      await listen("lsp://server-crashed", () => {
        logger.warn("LSPClient", "LSP server crashed, attempting auto-restart");
        const { actions } = useLspStore.getState();
        actions.setLspError("Language server crashed");

        // Auto-restart all tracked servers after a short delay
        setTimeout(() => {
          this.restartAllTrackedServers().catch((error) => {
            logger.error("LSPClient", "Failed to auto-restart LSP servers:", error);
          });
        }, 2000);
      });
      logger.debug("LSPClient", "Crash listener setup complete");
    } catch (error) {
      logger.error("LSPClient", "Failed to setup crash listener:", error);
    }
  }

  async start(
    workspacePath: string,
    representativeFilePath?: string,
  ): Promise<LspWorkspaceStartOutcome> {
    try {
      logger.debug("LSPClient", "Starting LSP with workspace:", workspacePath);

      if (workspacePath.startsWith("wsl://") || representativeFilePath?.startsWith("wsl://")) {
        logger.debug("LSPClient", `Skipping host LSP for WSL workspace ${workspacePath}`);
        return { kind: "unsupportedHost" };
      }

      const launch = representativeFilePath
        ? await resolveEditorLspLaunch(representativeFilePath, workspacePath)
        : null;
      if (!launch) {
        logger.debug("LSPClient", `No LSP server configured for workspace ${workspacePath}`);
        return { kind: "notConfigured" };
      }

      const serverKey = `${workspacePath}:${launch.languageId}`;
      const workspaceSession = getLspWorkspaceSessionSnapshot({
        workspacePath,
        languageId: launch.languageId,
      });
      if (workspaceSession?.phase === "ready") {
        if (representativeFilePath) {
          this.workspaceRepresentativeFiles.set(serverKey, representativeFilePath);
        }
        this.registerActiveServer(serverKey, launch.languageId);
        return { kind: "ready" } as const;
      }

      const existingTask = this.workspaceStartTasks.get(serverKey);
      if (existingTask) return existingTask;

      const task: Promise<LspWorkspaceStartOutcome> = (async (): Promise<LspWorkspaceStartOutcome> => {
        logger.debug(
          "LSPClient",
          `Using LSP server: ${launch.serverPath} for language: ${launch.languageId}`,
        );
        useLspStore.getState().actions.updateLspStatus("connecting");
        await invoke<void>("lsp_start", {
          workspacePath,
          serverPath: launch.serverPath,
          serverArgs: launch.serverArgs,
          languageId: launch.languageId,
          providerId: launch.providerId,
          tools: launch.tools || null,
          initializationOptions: launch.initializationOptions || null,
          runtimeExecutablePath: launch.runtimeExecutablePath || null,
          cacheDirectory: launch.cacheDirectory || null,
          environment: launch.environment || null,
          workspaceFingerprint: launch.workspaceFingerprint || null,
        });

        if (representativeFilePath) {
          this.workspaceRepresentativeFiles.set(serverKey, representativeFilePath);
        }
        this.registerActiveServer(serverKey, launch.languageId);
        logger.debug("LSPClient", "LSP started successfully for workspace:", workspacePath);
        return { kind: "ready" };
      })().finally(() => {
        if (this.workspaceStartTasks.get(serverKey) === task) {
          this.workspaceStartTasks.delete(serverKey);
        }
      });
      this.workspaceStartTasks.set(serverKey, task);
      return await task;
    } catch (error) {
      logger.error("LSPClient", "Failed to start LSP:", error);
      useLspStore.getState().actions.setLspError(getUserFacingLspErrorMessage(error));
      throw error;
    }
  }

  async stop(workspacePath: string): Promise<void> {
    try {
      logger.debug("LSPClient", "Stopping LSP for workspace:", workspacePath);
      const workspaceKey = trackedFileKey(workspacePath);
      const pendingStarts = [...this.workspaceStartTasks.entries()]
        .filter(([key]) => trackedFileKey(this.parseServerKey(key).workspacePath) === workspaceKey)
        .map(([, task]) => task);
      if (pendingStarts.length > 0) await Promise.allSettled(pendingStarts);
      await invoke<void>("lsp_stop", { workspacePath });

      // Remove all language servers for this workspace
      const serversToRemove = Array.from(this.activeLanguageServers).filter(
        (key) => trackedFileKey(this.parseServerKey(key).workspacePath) === workspaceKey,
      );
      for (const server of serversToRemove) {
        for (const filePath of this.activeServerFiles.get(server) ?? []) {
          const file = trackedFileKey(filePath);
          this.fileAttachmentIds.delete(file);
          this.fileStartTasks.delete(file);
          this.documentOpenTasks.delete(file);
          this.documents.delete(file);
        }
        this.activeLanguageServers.delete(server);
        this.activeServerFiles.delete(server);
        this.workspaceRepresentativeFiles.delete(server);
        const { languageId: language } = this.parseServerKey(server);
        if (language) {
          const displayName = getLanguageDisplayName(language);
          this.activeLanguages.delete(displayName);
        }
      }

      // Update status store
      this.updateLspStatus();

      logger.debug("LSPClient", "LSP stopped successfully for workspace:", workspacePath);
    } catch (error) {
      logger.error("LSPClient", "Failed to stop LSP:", error);
      throw error;
    }
  }

  async notifyWorkspaceFilesChanged(
    workspacePath: string,
    changes: Array<{ path: string; kind: "created" | "changed" | "deleted" }>,
  ): Promise<void> {
    if (changes.length === 0) return;
    await invoke<void>("lsp_workspace_files_changed", {
      workspacePath,
      languageId: JAVA_LANGUAGE_ID,
      changes,
    });
  }

  async startForFile(
    filePath: string,
    workspacePath: string,
    intent: LspFileStartIntent = "attach",
  ): Promise<LspFileAttachmentOutcome> {
    const attachmentKey = trackedFileKey(filePath);
    const currentAttachmentId = this.fileAttachmentIds.get(attachmentKey);
    const currentSession = getLspSessionSnapshot({ filePath });
    if (
      currentAttachmentId &&
      currentSession &&
      trackedFileKey(currentSession.workspacePath) === trackedFileKey(workspacePath)
    ) {
      this.registerActiveServer(
        `${currentSession.workspacePath}:${currentSession.languageId}`,
        currentSession.languageId,
        filePath,
      );
      return { kind: "attached", attachmentId: currentAttachmentId };
    }

    const pending = this.fileStartTasks.get(attachmentKey);
    if (pending && trackedFileKey(pending.workspacePath) === trackedFileKey(workspacePath)) {
      return pending.task;
    }

    const attachmentId = crypto.randomUUID();
    this.fileAttachmentIds.set(attachmentKey, attachmentId);
    const task = this.startFileAttachment(filePath, workspacePath, {
      kind: intent,
      attachmentId,
    }).finally(() => {
      if (this.fileStartTasks.get(attachmentKey)?.task === task) {
        this.fileStartTasks.delete(attachmentKey);
      }
    });
    this.fileStartTasks.set(attachmentKey, { workspacePath, task });
    return task;
  }

  private async startFileAttachment(
    filePath: string,
    workspacePath: string,
    attempt: LspFileStartAttempt,
  ): Promise<LspFileAttachmentOutcome> {
    const attachmentKey = trackedFileKey(filePath);
    const attachmentId = attempt.attachmentId;
    if (this.fileAttachmentIds.get(attachmentKey) !== attachmentId) {
      return { kind: "cancelled", reason: "superseded" };
    }
    const isCurrentAttachment = () => this.fileAttachmentIds.get(attachmentKey) === attachmentId;

    try {
      logger.debug("LSPClient", "Starting LSP for file:", filePath);

      if (workspacePath.startsWith("wsl://") || filePath.startsWith("wsl://")) {
        logger.debug("LSPClient", `Skipping host LSP for WSL file ${filePath}`);
        if (isCurrentAttachment()) this.fileAttachmentIds.delete(attachmentKey);
        return { kind: "cancelled", reason: "unsupportedHost" };
      }

      let launch: Awaited<ReturnType<typeof resolveEditorLspLaunch>> = null;
      try {
        launch = await resolveEditorLspLaunch(filePath, workspacePath);
      } catch (error) {
        if (attempt.kind !== "repairRetry" && !isBuiltInLspPath(filePath)) {
          const languageId = languageIdForEditorFile(filePath);
          if (languageId) {
            const repaired = await this.repairLanguageServerForFile(filePath, languageId);
            if (repaired.kind === "repaired") {
              return this.startFileAttachment(filePath, workspacePath, {
                kind: "repairRetry",
                attachmentId,
              });
            }
          }
        }
        throw error;
      }

      if (!launch) {
        const languageId = languageIdForEditorFile(filePath);
        if (languageId && attempt.kind !== "repairRetry" && !isBuiltInLspPath(filePath)) {
          const repaired = await this.repairLanguageServerForFile(filePath, languageId);
          if (repaired.kind === "repaired") {
            return this.startFileAttachment(filePath, workspacePath, {
              kind: "repairRetry",
              attachmentId,
            });
          }
        }

        const message = languageId
          ? `Language server for ${getLanguageDisplayName(languageId)} could not be resolved.`
          : "No language server is configured for this file.";
        if (languageId) {
          logger.warn(
            "LSPClient",
            `LSP configured for language '${languageId}' but server binary is missing (file: ${filePath})`,
          );
        } else {
          logger.debug("LSPClient", `No LSP server configured for ${filePath}`);
        }
        throw new Error(message);
      }

      const languageId = launch.languageId;
      logger.debug(
        "LSPClient",
        `Using LSP server: ${launch.serverPath} for language: ${languageId}`,
      );

      const serverKey = `${workspacePath}:${languageId}`;
      if (attempt.kind !== "attach") {
        clearLanguageServerFailure(this.failedLanguageServers, serverKey);
      }
      if (isLanguageServerFailureCoolingDown(this.failedLanguageServers, serverKey, Date.now())) {
        logger.debug(
          "LSPClient",
          `Skipping LSP restart for ${languageId} in ${workspacePath} during startup failure cooldown`,
        );
        throw new Error(
          `${getLanguageDisplayName(languageId)} language server previously failed to start.`,
        );
      }

      useLspStore.getState().actions.updateLspStatus("connecting");

      if (!isCurrentAttachment()) return { kind: "cancelled", reason: "superseded" };

      logger.debug("LSPClient", `Invoking lsp_start_for_file with:`, {
        filePath,
        workspacePath,
        serverPath: launch.serverPath,
        serverArgs: launch.serverArgs,
      });

      try {
        await invoke<void>("lsp_start_for_file", {
          filePath,
          workspacePath,
          serverPath: launch.serverPath,
          serverArgs: launch.serverArgs,
          languageId,
          providerId: launch.providerId,
          tools: launch.tools || null,
          initializationOptions: launch.initializationOptions || null,
          runtimeExecutablePath: launch.runtimeExecutablePath || null,
          cacheDirectory: launch.cacheDirectory || null,
          environment: launch.environment || null,
          workspaceFingerprint: launch.workspaceFingerprint || null,
          attachmentId,
        });
        if (!isCurrentAttachment()) {
          await invoke<void>("lsp_stop_for_file", { filePath, attachmentId });
          return { kind: "cancelled", reason: "superseded" };
        }
        clearLanguageServerFailure(this.failedLanguageServers, serverKey);
        this.registerActiveServer(serverKey, languageId, filePath);
      } catch (error) {
        recordLanguageServerFailure(this.failedLanguageServers, serverKey, Date.now());
        if (attempt.kind !== "repairRetry" && this.isRepairableStartupError(error)) {
          const repaired = await this.repairLanguageServerForFile(filePath, languageId);
          if (repaired.kind === "repaired") {
            return this.startFileAttachment(filePath, workspacePath, {
              kind: "repairRetry",
              attachmentId,
            });
          }
        }
        throw error;
      }

      logger.debug("LSPClient", "LSP started successfully for file:", filePath);
      return { kind: "attached", attachmentId };
    } catch (error) {
      if (!isCurrentAttachment()) return { kind: "cancelled", reason: "superseded" };
      this.fileAttachmentIds.delete(attachmentKey);
      logger.error("LSPClient", "Failed to start LSP for file:", error);
      const { actions } = useLspStore.getState();
      actions.setLspError(getUserFacingLspErrorMessage(error));
      throw error;
    }
  }

  hasSessionForFile(filePath: string): boolean {
    return getLspSessionSnapshot({ filePath }) !== null;
  }

  getDocumentAvailability(
    target: LspDocumentTargetInput,
    feature?: string,
  ): LspDocumentAvailability {
    const document = normalizeLspDocumentTarget(target);
    const session = getLspSessionSnapshot({
      filePath: document.filePath,
      sessionFilePath: document.sessionFilePath,
    });
    const languageId =
      document.languageId ?? session?.languageId ?? languageIdForEditorFile(document.filePath);
    if (!session) return { phase: "unavailable", languageId };
    if (session.phase === "failed" || session.phase === "stopped") {
      return {
        phase: "failed",
        languageId,
        workspacePath: session.workspacePath,
        sessionPhase: session.phase,
      };
    }
    if (session.phase !== "ready") {
      return {
        phase: "preparing",
        languageId,
        workspacePath: session.workspacePath,
        sessionPhase: session.phase,
      };
    }
    const featureSupport = !feature
      ? "supported"
      : session.featureState.phase === "unknown"
        ? "unknown"
        : session.featureState.features.includes(feature)
          ? "supported"
          : "unsupported";
    return {
      phase: "ready",
      languageId,
      workspacePath: session.workspacePath,
      feature: featureSupport,
    };
  }

  async ensureDocumentReady(
    target: LspDocumentTargetInput,
    workspacePath: string,
    content: string,
    feature?: string,
  ): Promise<LspDocumentAvailability> {
    const initial = this.getDocumentAvailability(target, feature);
    if (isDocumentFeatureAvailable(initial)) return initial;

    const document = normalizeLspDocumentTarget(target);
    const sessionFilePath = lspSessionFilePath(document);
    // A virtual JDT document borrows a physical source session. Reconstructing
    // that source document from virtual class text would corrupt synchronization.
    if (sessionFilePath !== document.filePath) return initial;

    const attachment = await this.startForFile(sessionFilePath, workspacePath);
    if (attachment.kind !== "attached") return this.getDocumentAvailability(document, feature);
    const { attachmentId } = attachment;

    const trackedDocument = this.documents.get(trackedFileKey(sessionFilePath));
    if (trackedDocument?.phase !== "open" || trackedDocument.attachmentId !== attachmentId) {
      await this.notifyDocumentOpen(sessionFilePath, content, attachmentId);
    }
    return this.getDocumentAvailability(document, feature);
  }

  async stopForFile(filePath: string, requestedAttachmentId?: string): Promise<void> {
    const attachmentKey = trackedFileKey(filePath);
    const attachmentId = requestedAttachmentId ?? this.fileAttachmentIds.get(attachmentKey);
    if (!attachmentId) return;
    if (this.fileAttachmentIds.get(attachmentKey) === attachmentId) {
      this.fileAttachmentIds.delete(attachmentKey);
    }

    try {
      logger.debug("LSPClient", "Stopping LSP for file:", filePath);
      const languageId = languageIdForEditorFile(filePath);
      await invoke<void>("lsp_stop_for_file", { filePath, attachmentId });

      // A newer editor attachment owns the same path now. The adapter ignored
      // this stale stop, so its frontend tracking must remain intact too.
      if (this.fileAttachmentIds.has(attachmentKey)) return;

      const trackedDocument = this.documents.get(attachmentKey);
      if (trackedDocument?.attachmentId === attachmentId) {
        this.documents.delete(attachmentKey);
        useDiagnosticsStore.getState().actions.clearDiagnosticsForOwner(filePath, "lsp");
        useLspStore.getState().actions.markDocumentStateChanged();
      }

      if (languageId) {
        const activeKey = this.findServerKeyForFile(filePath, languageId);
        if (activeKey) {
          this.removeTrackedFile(activeKey, filePath);
          const stillActiveForServer = this.activeServerFiles.has(activeKey);
          const workspaceSession = getLspWorkspaceSessionSnapshot({
            workspacePath: this.parseServerKey(activeKey).workspacePath,
            languageId,
          });
          if (!stillActiveForServer && !(languageId === JAVA_LANGUAGE_ID && workspaceSession)) {
            this.activeLanguageServers.delete(activeKey);
          }
          clearLanguageServerFailure(this.failedLanguageServers, activeKey);
        }

        const displayName = getLanguageDisplayName(languageId);
        const stillActiveForLanguage = Array.from(this.activeLanguageServers).some((key) =>
          key.endsWith(`:${languageId}`),
        );
        if (!stillActiveForLanguage) {
          this.activeLanguages.delete(displayName);
        }

        this.updateLspStatus();
      }

      logger.debug("LSPClient", "LSP stopped successfully for file:", filePath);
    } catch (error) {
      logger.error("LSPClient", "Failed to stop LSP for file:", error);
      throw error;
    }
  }

  async stopTrackedServer(serverKey: string): Promise<void> {
    const trackedFilePath = this.activeServerFiles.get(serverKey)?.values().next().value;
    if (!trackedFilePath) {
      const { workspacePath } = this.parseServerKey(serverKey);
      await this.stop(workspacePath);
      return;
    }

    await this.stopForFile(trackedFilePath);
  }

  async restartForFile(filePath: string, workspacePath: string, content: string): Promise<void> {
    const { actions } = useLspStore.getState();

    try {
      actions.updateLspStatus("connecting");
      actions.clearLspError();

      await this.notifyDocumentClose(filePath);
      await this.stopForFile(filePath);
      const attachment = await this.startForFile(filePath, workspacePath, "manualRestart");
      if (attachment.kind !== "attached") {
        throw new Error("Language server failed to start.");
      }
      await this.notifyDocumentOpen(filePath, content, attachment.attachmentId);
    } catch (error) {
      logger.error("LSPClient", "Failed to restart LSP for file:", error);
      actions.setLspError(getUserFacingLspErrorMessage(error));
      throw error;
    }
  }

  async restartTrackedServer(serverKey: string): Promise<void> {
    const trackedFilePath = this.activeServerFiles.get(serverKey)?.values().next().value;
    if (!trackedFilePath) {
      const representativeFilePath = this.workspaceRepresentativeFiles.get(serverKey);
      if (!representativeFilePath) {
        throw new Error("No representative file for this language server");
      }
      const { workspacePath } = this.parseServerKey(serverKey);
      await this.stop(workspacePath);
      await this.start(workspacePath, representativeFilePath);
      return;
    }

    const filePath = trackedFilePath;
    const buffer = useBufferStore.getState().buffers.find((entry) => entry.path === filePath);
    const content = buffer && hasTextContent(buffer) ? buffer.content : "";
    await this.restartForFile(filePath, this.parseServerKey(serverKey).workspacePath, content);
  }

  async restartAllTrackedServers(): Promise<void> {
    const serverKeys = this.getActiveServerEntries().map((entry) => entry.key);
    await Promise.all(serverKeys.map((serverKey) => this.restartTrackedServer(serverKey)));
  }

  async stopAll(): Promise<void> {
    const workspaces = new Set<string>();
    for (const key of this.activeLanguageServers) {
      workspaces.add(this.parseServerKey(key).workspacePath);
    }
    await Promise.all(Array.from(workspaces).map((ws) => this.stop(ws)));
  }

  async getCompletions(
    target: LspDocumentTargetInput,
    line: number,
    character: number,
  ): Promise<CompletionItem[]> {
    const document = normalizeLspDocumentTarget(target);
    try {
      logger.debug(
        "LSPClient",
        `Getting completions for ${document.filePath}:${line}:${character}`,
      );
      logger.debug(
        "LSPClient",
        `Active language servers: ${Array.from(this.activeLanguageServers).join(", ")}`,
      );
      const completions = await invoke<CompletionItem[]>("lsp_get_completions", {
        ...lspDocumentRequestArgs(document),
        line,
        character,
      });
      if (completions.length === 0) {
        logger.warn("LSPClient", "LSP returned 0 completions - checking LSP status");
      } else {
        logger.debug("LSPClient", `Got ${completions.length} completions from LSP server`);
      }
      return completions;
    } catch (error) {
      logger.error("LSPClient", "LSP completion error:", error);
      return [];
    }
  }

  async getHover(
    target: LspDocumentTargetInput,
    line: number,
    character: number,
  ): Promise<Hover | null> {
    try {
      return await invoke<Hover | null>("lsp_get_hover", {
        ...lspDocumentRequestArgs(target),
        line,
        character,
      });
    } catch (error) {
      if (!isBenignHoverError(error)) {
        logger.error("LSPClient", "LSP hover error:", error);
      }
      return null;
    }
  }

  private async getNavigationLocations(
    command: "lsp_get_definition" | "lsp_get_implementation" | "lsp_get_type_definition",
    label: string,
    target: LspDocumentTargetInput,
    line: number,
    character: number,
  ): Promise<LspLocation[] | null> {
    const document = normalizeLspDocumentTarget(target);
    try {
      logger.debug("LSPClient", `Getting ${label} for ${document.filePath}:${line}:${character}`);
      const locations = await invoke<LspLocation[] | null>(command, {
        ...lspDocumentRequestArgs(document),
        line,
        character,
      });
      if (locations) {
        logger.debug("LSPClient", `Got ${label}: ${JSON.stringify(locations)}`);
      }
      return locations;
    } catch (error) {
      logger.error("LSPClient", `LSP ${label} error:`, error);
      return null;
    }
  }

  async getDefinition(
    target: LspDocumentTargetInput,
    line: number,
    character: number,
  ): Promise<LspLocation[] | null> {
    return this.getNavigationLocations("lsp_get_definition", "definition", target, line, character);
  }

  async getImplementation(
    target: LspDocumentTargetInput,
    line: number,
    character: number,
  ): Promise<LspLocation[] | null> {
    return this.getNavigationLocations(
      "lsp_get_implementation",
      "implementation",
      target,
      line,
      character,
    );
  }

  async getTypeDefinition(
    target: LspDocumentTargetInput,
    line: number,
    character: number,
  ): Promise<LspLocation[] | null> {
    return this.getNavigationLocations(
      "lsp_get_type_definition",
      "type definition",
      target,
      line,
      character,
    );
  }

  async getVirtualDocument(filePath: string, virtualUri: string): Promise<string | null> {
    try {
      return await invoke<string | null>("lsp_get_virtual_document", {
        filePath,
        virtualUri,
      });
    } catch (error) {
      logger.error("LSPClient", `LSP virtual document error for ${virtualUri}:`, error);
      return null;
    }
  }

  async getSemanticTokens(filePath: string): Promise<LspSemanticTokensResponse | null> {
    if (!isLspSemanticCommandSupported("lsp_get_semantic_tokens")) return null;
    try {
      return await invoke<LspSemanticTokensResponse>("lsp_get_semantic_tokens", { filePath });
    } catch (error) {
      if (isCanceledLspRequest(error)) return null;
      logger.error("LSPClient", "LSP semantic tokens error:", error);
      return null;
    }
  }

  async getCodeLens(target: LspDocumentTargetInput): Promise<
    {
      line: number;
      utf16Column: number;
      title: string;
      command?: string;
      arguments?: unknown[];
    }[]
  > {
    try {
      return await invoke("lsp_get_code_lens", lspDocumentRequestArgs(target));
    } catch (error) {
      if (isCanceledLspRequest(error)) return [];
      logger.error("LSPClient", "LSP code lens error:", error);
      return [];
    }
  }

  async getJavaNavigationMarkers(
    target: LspDocumentTargetInput,
  ): Promise<JavaImplementationMarker[]> {
    try {
      const result = await invoke<{ markers?: unknown[] }>(
        "java_navigation_markers",
        lspDocumentRequestArgs(target),
      );
      return normalizeJavaImplementationMarkers(result.markers);
    } catch (error) {
      // The gutter owner distinguishes transient cancellation during JDTLS
      // startup from a valid empty marker result and retries it with a bound.
      if (isCanceledLspRequest(error)) throw error;
      logger.error("LSPClient", "Java navigation marker error:", error);
      throw error;
    }
  }

  async resolveJavaNavigation(
    target: LspDocumentTargetInput,
    marker: JavaImplementationMarker,
  ): Promise<LspLocation[]> {
    try {
      const result = await invoke<{ locations?: LspLocation[] }>("java_resolve_navigation", {
        ...lspDocumentRequestArgs(target),
        line: marker.line,
        character: marker.utf16Column,
        direction: marker.direction,
        relation: marker.relation,
      });
      return Array.isArray(result.locations) ? result.locations : [];
    } catch (error) {
      if (isCanceledLspRequest(error)) return [];
      logger.error("LSPClient", "Java navigation resolution error:", error);
      return [];
    }
  }

  async getInlayHints(
    target: LspDocumentTargetInput,
    startLine: number,
    endLine: number,
  ): Promise<
    {
      line: number;
      character: number;
      label: string;
      kind?: string;
      paddingLeft: boolean;
      paddingRight: boolean;
    }[]
  > {
    try {
      return await invoke("lsp_get_inlay_hints", {
        ...lspDocumentRequestArgs(target),
        startLine,
        endLine,
      });
    } catch (error) {
      if (isCanceledLspRequest(error)) return [];
      logger.error("LSPClient", "LSP inlay hints error:", error);
      return [];
    }
  }

  async getDocumentSymbols(filePath: string): Promise<
    {
      name: string;
      kind: string;
      detail?: string;
      line: number;
      character: number;
      endLine: number;
      endCharacter: number;
      containerName?: string;
      hierarchyPath?: number[];
    }[]
  > {
    if (!isLspSemanticCommandSupported("lsp_get_document_symbols")) return [];
    try {
      logger.debug("LSPClient", `Getting document symbols for ${filePath}`);
      const symbols = await invoke<
        {
          name: string;
          kind: string;
          detail?: string;
          line: number;
          character: number;
          endLine: number;
          endCharacter: number;
          containerName?: string;
          hierarchyPath?: number[];
        }[]
      >("lsp_get_document_symbols", { filePath });
      logger.debug("LSPClient", `Got ${symbols.length} document symbols`);
      return symbols;
    } catch (error) {
      logger.error("LSPClient", "LSP document symbols error:", error);
      return [];
    }
  }

  async getWorkspaceSymbols(
    query: string,
    workspacePath: string,
  ): Promise<
    {
      name: string;
      kind: string;
      detail?: string;
      line: number;
      character: number;
      endLine: number;
      endCharacter: number;
      containerName?: string;
      filePath: string;
    }[]
  > {
    if (!isLspSemanticCommandSupported("lsp_get_workspace_symbols")) return [];
    try {
      logger.debug("LSPClient", `Getting workspace symbols for "${query}" in ${workspacePath}`);
      const symbols = await invoke<
        {
          name: string;
          kind: string;
          detail?: string;
          line: number;
          character: number;
          endLine: number;
          endCharacter: number;
          containerName?: string;
          filePath: string;
        }[]
      >("lsp_get_workspace_symbols", { workspacePath, query });
      logger.debug("LSPClient", `Got ${symbols.length} workspace symbols`);
      return symbols;
    } catch (error) {
      if (isCanceledLspRequest(error)) return [];
      logger.error("LSPClient", "LSP workspace symbols error:", error);
      return [];
    }
  }

  async getSignatureHelp(
    filePath: string,
    line: number,
    character: number,
  ): Promise<{
    signatures: {
      label: string;
      documentation?: { kind: string; value: string } | string;
      parameters?: {
        label: string | [number, number];
        documentation?: { kind: string; value: string } | string;
      }[];
      activeParameter?: number;
    }[];
    activeSignature?: number;
    activeParameter?: number;
  } | null> {
    if (!isLspSemanticCommandSupported("lsp_get_signature_help")) return null;
    try {
      return await invoke("lsp_get_signature_help", {
        filePath,
        line,
        character,
      });
    } catch (error) {
      logger.error("LSPClient", "LSP signature help error:", error);
      return null;
    }
  }

  async getSignatureTriggerCharacters(filePath: string): Promise<string[]> {
    if (!isLspSemanticCommandSupported("lsp_get_signature_trigger_characters")) return [];
    try {
      return await invoke<string[]>("lsp_get_signature_trigger_characters", { filePath });
    } catch (error) {
      logger.debug("LSPClient", "LSP signature trigger characters unavailable:", error);
      return [];
    }
  }

  async formatDocument(target: LspDocumentTargetInput, content: string): Promise<string | null> {
    try {
      const edits = await invoke<LspTextEdit[]>(
        "lsp_format_document",
        lspDocumentRequestArgs(target),
      );
      if (!edits.length) return content;
      return applyTextEditsToContent(content, edits);
    } catch (error) {
      logger.debug("LSPClient", "LSP document formatting unavailable:", error);
      return null;
    }
  }

  async formatRange(
    filePath: string,
    content: string,
    range: {
      start: { line: number; character: number };
      end: { line: number; character: number };
    },
  ): Promise<string | null> {
    if (!isLspSemanticCommandSupported("lsp_format_range")) return null;
    try {
      const edits = await invoke<LspTextEdit[]>("lsp_format_range", {
        filePath,
        startLine: range.start.line,
        startCharacter: range.start.character,
        endLine: range.end.line,
        endCharacter: range.end.character,
      });
      if (!edits.length) return content;
      return applyTextEditsToContent(content, edits);
    } catch (error) {
      logger.debug("LSPClient", "LSP range formatting unavailable:", error);
      return null;
    }
  }

  async getReferences(
    target: LspDocumentTargetInput,
    line: number,
    character: number,
  ): Promise<
    | {
        uri: string;
        range: {
          start: { line: number; character: number };
          end: { line: number; character: number };
        };
      }[]
    | null
  > {
    const document = normalizeLspDocumentTarget(target);
    try {
      logger.debug("LSPClient", `Getting references for ${document.filePath}:${line}:${character}`);
      const references = await invoke<
        | {
            uri: string;
            range: {
              start: { line: number; character: number };
              end: { line: number; character: number };
            };
          }[]
        | null
      >("lsp_get_references", {
        ...lspDocumentRequestArgs(document),
        line,
        character,
      });
      if (references) {
        logger.debug("LSPClient", `Got ${references.length} references`);
      }
      return references;
    } catch (error) {
      logger.error("LSPClient", "LSP references error:", error);
      return null;
    }
  }

  async rename(
    target: LspDocumentTargetInput,
    line: number,
    character: number,
    newName: string,
  ): Promise<WorkspaceEdit | null> {
    const document = normalizeLspDocumentTarget(target);
    try {
      logger.debug(
        "LSPClient",
        `Renaming at ${document.filePath}:${line}:${character} to "${newName}"`,
      );
      const result = await invoke<WorkspaceEdit | null>("lsp_rename", {
        ...lspDocumentRequestArgs(document),
        line,
        character,
        newName,
      });
      if (result) {
        logger.debug("LSPClient", `Rename result: ${JSON.stringify(result)}`);
      }
      return result;
    } catch (error) {
      logger.error("LSPClient", "LSP rename error:", error);
      return null;
    }
  }

  async prepareRename(
    filePath: string,
    line: number,
    character: number,
  ): Promise<PrepareRenameResult | null> {
    if (!isLspSemanticCommandSupported("lsp_prepare_rename")) return null;
    try {
      return await invoke<PrepareRenameResult | null>("lsp_prepare_rename", {
        filePath,
        line,
        character,
      });
    } catch (error) {
      logger.debug("LSPClient", "LSP prepare rename unavailable:", error);
      return null;
    }
  }

  async getCodeActions(
    target: LspDocumentTargetInput,
    diagnostic: Diagnostic,
  ): Promise<DiagnosticCodeAction[]> {
    try {
      return await invoke<DiagnosticCodeAction[]>("lsp_get_code_actions", {
        ...lspDocumentRequestArgs(target),
        diagnostic: {
          line: diagnostic.line,
          column: diagnostic.column,
          endLine: diagnostic.endLine,
          endColumn: diagnostic.endColumn,
          message: diagnostic.message,
          source: diagnostic.source,
          code: diagnostic.code,
          severity: diagnostic.severity,
        },
      });
    } catch (error) {
      logger.warn("LSPClient", "LSP code action request failed:", error);
      return [];
    }
  }

  async applyCodeAction(
    target: LspDocumentTargetInput,
    actionPayload: unknown,
  ): Promise<ApplyDiagnosticCodeActionResult> {
    try {
      let appliedEdit = false;
      const edit = getCodeActionEdit(actionPayload);
      if (isWorkspaceEdit(edit)) {
        await applyWorkspaceEdit(edit);
        appliedEdit = true;

        if (!hasCodeActionCommand(actionPayload)) {
          return { applied: true };
        }

        actionPayload = withoutWorkspaceEdit(actionPayload);
      }

      const result = await invoke<ApplyDiagnosticCodeActionResult>("lsp_apply_code_action", {
        ...lspDocumentRequestArgs(target),
        actionPayload,
      });

      return appliedEdit && !result.applied ? { applied: true, reason: result.reason } : result;
    } catch (error) {
      logger.warn("LSPClient", "LSP apply code action failed:", error);
      return {
        applied: false,
        reason: stringifyLspError(error),
      };
    }
  }

  async notifyDocumentOpen(
    filePath: string,
    content: string,
    attachmentId?: string,
  ): Promise<void> {
    const attachmentKey = trackedFileKey(filePath);
    const currentAttachmentId = this.fileAttachmentIds.get(attachmentKey);
    if (attachmentId && currentAttachmentId !== attachmentId) return;
    const ownerAttachmentId = attachmentId ?? currentAttachmentId;
    if (!ownerAttachmentId) return;

    const openDocument = this.documents.get(attachmentKey);
    if (openDocument?.phase === "open" && openDocument.attachmentId === ownerAttachmentId) {
      return;
    }
    const pendingOpen = this.documentOpenTasks.get(attachmentKey);
    if (pendingOpen?.attachmentId === ownerAttachmentId) return pendingOpen.task;

    const task: Promise<void> = (async () => {
      try {
        logger.debug("LSPClient", `Opening document: ${filePath}`);
        const languageId = languageIdForEditorFile(filePath);
        await invoke<void>("lsp_document_open", {
          filePath,
          content,
          languageId,
          attachmentId: ownerAttachmentId,
        });
        if (this.fileAttachmentIds.get(attachmentKey) !== ownerAttachmentId) return;
        this.documents.set(attachmentKey, {
          filePath,
          attachmentId: ownerAttachmentId,
          version: 1,
          phase: "open",
        });
        useLspStore.getState().actions.markDocumentStateChanged();
      } catch (error) {
        logger.error("LSPClient", "LSP document open error:", error);
        throw error;
      }
    })().finally(() => {
      if (this.documentOpenTasks.get(attachmentKey)?.task === task) {
        this.documentOpenTasks.delete(attachmentKey);
      }
    });
    this.documentOpenTasks.set(attachmentKey, { attachmentId: ownerAttachmentId, task });
    return task;
  }

  async notifyDocumentChange(
    filePath: string,
    content: string | undefined,
    version: number,
    contentChanges?: Array<{
      rangeOffset: number;
      rangeLength: number;
      text: string;
      startLine?: number;
      startColumn?: number;
      endLine?: number;
      endColumn?: number;
    }>,
  ): Promise<void> {
    const attachmentKey = trackedFileKey(filePath);
    const attachmentId = this.fileAttachmentIds.get(attachmentKey);
    const document = this.documents.get(attachmentKey);
    if (!attachmentId || document?.phase !== "open" || document.attachmentId !== attachmentId) {
      return;
    }

    try {
      await invoke<void>("lsp_document_change", {
        filePath,
        content,
        version,
        contentChanges,
        attachmentId,
      });
      const current = this.documents.get(attachmentKey);
      if (current?.phase === "open" && current.attachmentId === attachmentId) {
        this.documents.set(attachmentKey, { ...current, version });
      }
    } catch (error) {
      logger.error("LSPClient", "LSP document change error:", error);
      throw error;
    }
  }

  async notifyDocumentSave(filePath: string, content: string): Promise<void> {
    const attachmentKey = trackedFileKey(filePath);
    const attachmentId = this.fileAttachmentIds.get(attachmentKey);
    const document = this.documents.get(attachmentKey);
    if (!attachmentId || document?.phase !== "open" || document.attachmentId !== attachmentId) {
      return;
    }

    try {
      await invoke<void>("lsp_document_save", { filePath, content, attachmentId });
    } catch (error) {
      logger.error("LSPClient", "LSP document save error:", error);
      throw error;
    }
  }

  async notifyDocumentClose(filePath: string, requestedAttachmentId?: string): Promise<void> {
    const attachmentKey = trackedFileKey(filePath);
    const document = this.documents.get(attachmentKey);
    const attachmentId = requestedAttachmentId ?? document?.attachmentId;
    if (!attachmentId || document?.phase !== "open" || document.attachmentId !== attachmentId) {
      return;
    }

    this.documents.set(attachmentKey, { ...document, phase: "closing" });
    useDiagnosticsStore.getState().actions.clearDiagnosticsForOwner(filePath, "lsp");
    useLspStore.getState().actions.markDocumentStateChanged();

    try {
      await invoke<void>("lsp_document_close", { filePath, attachmentId });
    } catch (error) {
      logger.error("LSPClient", "LSP document close error:", error);
      throw error;
    } finally {
      const current = this.documents.get(attachmentKey);
      if (current?.attachmentId === attachmentId) this.documents.delete(attachmentKey);
    }
  }

  async isLanguageSupported(filePath: string): Promise<boolean> {
    try {
      const { extensionRegistry } = await import("@/extensions/registry/extension-registry");
      return Boolean(extensionRegistry.getLspServerPath(filePath));
    } catch (error) {
      logger.error("LSPClient", "LSP language support check error:", error);
      return false;
    }
  }

  getActiveWorkspaces(): string[] {
    const workspaces = new Set<string>();
    for (const key of this.activeLanguageServers) {
      workspaces.add(this.parseServerKey(key).workspacePath);
    }
    return Array.from(workspaces);
  }

  isWorkspaceActive(workspacePath: string): boolean {
    // Check if any language server is running for this workspace
    for (const key of this.activeLanguageServers) {
      if (key.startsWith(`${workspacePath}:`)) {
        return true;
      }
    }
    return false;
  }
}
