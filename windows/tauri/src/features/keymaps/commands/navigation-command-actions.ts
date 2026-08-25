import { editorAPI } from "@/features/editor/extensions/api";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { useEditorStateStore } from "@/features/editor/stores/state.store";
import { useJumpListStore } from "@/features/editor/stores/jump-list.store";
import { navigateToJumpEntry } from "@/features/editor/utils/jump-navigation";
import { getLineTextFromContent, getLineTextsFromContent } from "@/features/editor/utils/position";
import { useReferencesStore } from "@/features/references/stores/references.store";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { languageDisplayName } from "@/features/editor/lsp/language-server-feedback";
import {
  languageServerNavigationBlock,
  type LanguageServerNavigationBlock,
} from "@/features/editor/lsp/language-server-navigation";
import { resolveLombokAccessorDefinition } from "@/features/editor/lsp/lombok-accessor-navigation";
import { openLspNavigationLocation } from "@/features/editor/lsp/navigation-target";
import {
  lspDocumentTargetForEditor,
  type LspDocumentTarget,
  type LspDocumentTargetInput,
} from "@/features/editor/lsp/lsp-document-target";
import { definitionLocationsFromCommandArgs } from "@/features/editor/lsp/definition-navigation-hint";
import { navigationLocationPresentation } from "@/features/editor/lsp/navigation-location-presentation";
import type { LspDocumentAvailability, LspLocation } from "@/features/editor/lsp/lsp-client";
import {
  normalizeJavaImplementationMarkers,
  type JavaImplementationMarker,
} from "@/features/editor/lsp/java-navigation-models";
import { useLspStore } from "@/features/editor/lsp/stores/lsp.store";
import type { EditorContent } from "@/features/panes/types/pane-content.types";
import { useSpringStore } from "@/features/spring/stores/spring.store";
import type { SpringNavigationLocation } from "@/features/spring/types/spring.types";
import {
  resolveSpringDefinitions,
  resolveSpringReferences,
} from "@/features/spring/utils/spring-navigation";
import { useUIState } from "@/features/window/stores/ui-state.store";
import { useProjectStore } from "@/features/window/stores/project.store";
import { createTranslator } from "@/i18n/locale";
import { logger } from "@/features/editor/utils/logger";
import { normalizePath } from "@/utils/path-helpers";
import { showPromptDialog } from "@/ui/dialog";
import { toast } from "sonner";

type LspNavigationClient = {
  getDefinition: (
    target: LspDocumentTargetInput,
    line: number,
    character: number,
  ) => Promise<LspLocation[] | null>;
  getImplementation: (
    target: LspDocumentTargetInput,
    line: number,
    character: number,
  ) => Promise<LspLocation[] | null>;
  getTypeDefinition: (
    target: LspDocumentTargetInput,
    line: number,
    character: number,
  ) => Promise<LspLocation[] | null>;
  resolveJavaNavigation: (
    target: LspDocumentTargetInput,
    marker: JavaImplementationMarker,
  ) => Promise<LspLocation[]>;
  getDocumentAvailability: (
    target: LspDocumentTargetInput,
    feature?: string,
  ) => LspDocumentAvailability;
  ensureDocumentReady: (
    target: LspDocumentTargetInput,
    workspacePath: string,
    content: string,
    feature?: string,
  ) => Promise<LspDocumentAvailability>;
  getVirtualDocument: (filePath: string, virtualUri: string) => Promise<string | null>;
};

const NAVIGATION_LANGUAGE_SERVER_TOAST_ID = "navigation-language-server-readiness";

const getCurrentTranslator = () =>
  createTranslator(useSettingsStore.getState().settings.displayLanguage);

function translateNavigationLabel(label: string): string {
  const t = getCurrentTranslator();
  if (label === "definition") return t("navigation.definition");
  if (label === "implementation") return t("navigation.implementation");
  if (label === "type definition") return t("navigation.typeDefinition");
  if (label === "reference") return t("navigation.reference");
  return label;
}

function activeEditorNavigationContext() {
  const bufferStore = useBufferStore.getState();
  const activeBuffer = bufferStore.buffers.find(
    (buffer) => buffer.id === bufferStore.activeBufferId,
  );
  const editorState = useEditorStateStore.getState();
  if (!activeBuffer || activeBuffer.type !== "editor" || !activeBuffer.path) return null;
  return { bufferStore, activeBuffer, editorState };
}

function canonicalizeEditorPath(path: string): string {
  return normalizePath(path).replace(/^\/([A-Za-z]:)/, "$1");
}

function isCurrentNavigationTarget(
  filePath: string,
  line: number,
  targetPath: string,
  targetLine: number,
): boolean {
  return (
    canonicalizeEditorPath(filePath) === canonicalizeEditorPath(targetPath) && line === targetLine
  );
}

function navigationBlockMessage(
  block: LanguageServerNavigationBlock,
  feature: string,
): string {
  const t = getCurrentTranslator();
  const name = languageDisplayName(block.languageId);
  switch (block.reason) {
    case "preparing":
      return t("lsp.preparingNamed", { name });
    case "failed":
      return t("lsp.failedNamed", { name });
    case "unsupported":
      return t("lsp.unsupportedFeatureNamed", {
        name,
        feature: translateNavigationLabel(feature),
      });
    case "notReady":
      return t("lsp.notReadyNamed", { name });
  }
}

function unavailableLanguageServerBlock(
  buffer: EditorContent,
  feature: string,
  lspClient: Pick<LspNavigationClient, "getDocumentAvailability">,
): LanguageServerNavigationBlock | null {
  const availability = lspClient.getDocumentAvailability(
    lspDocumentTargetForEditor(buffer),
    feature,
  );
  const globalStatus = useLspStore.getState().lspStatus;
  return languageServerNavigationBlock({
    availability,
    fallbackStatus: globalStatus.status,
  });
}

async function ensureNavigationLanguageServer(
  buffer: EditorContent,
  feature: string,
  lspClient: Pick<LspNavigationClient, "ensureDocumentReady" | "getDocumentAvailability">,
): Promise<"proceed" | "deferred"> {
  const block = unavailableLanguageServerBlock(buffer, feature, lspClient);
  if (!block) return "proceed";

  const workspacePath = useProjectStore.getState().rootFolderPath;
  if (!workspacePath) {
    toast.error(navigationBlockMessage(block, feature), {
      id: NAVIGATION_LANGUAGE_SERVER_TOAST_ID,
    });
    return "deferred";
  }

  const target = lspDocumentTargetForEditor(buffer);
  toast.info(
    navigationBlockMessage(
      { reason: "preparing", languageId: block.languageId },
      feature,
    ),
    { id: NAVIGATION_LANGUAGE_SERVER_TOAST_ID, duration: 3500 },
  );

  // Attach the current buffer in the background, but this user action ends
  // here. Continuing after readiness would move the editor long after the user
  // has switched context.
  void lspClient
    .ensureDocumentReady(target, workspacePath, buffer.content, feature)
    .catch((error) => {
      logger.warn("LSPNavigation", "Background document attachment failed", error);
    });
  return "deferred";
}

function springLocationsForActiveFile(
  kind: "definition" | "references",
): SpringNavigationLocation[] {
  const context = activeEditorNavigationContext();
  const springState = useSpringStore.getState();
  if (!context || !springState.root) return [];
  return kind === "definition"
    ? resolveSpringDefinitions(
        springState.index,
        springState.root,
        context.activeBuffer.path,
        context.editorState.cursorPosition.line,
      )
    : resolveSpringReferences(
        springState.index,
        springState.root,
        context.activeBuffer.path,
        context.editorState.cursorPosition.line,
      );
}

async function navigateToSpringLocation(location: SpringNavigationLocation): Promise<void> {
  await goToActiveLspLocation(
    "definition",
    async () => [
      {
        uri: location.filePath,
        range: {
          start: { line: location.line, character: location.column },
          end: { line: location.line, character: location.column },
        },
      },
    ],
    { requireLanguageServer: false },
  );
}

async function presentSpringReferences(
  locations: SpringNavigationLocation[],
  symbol: string,
): Promise<void> {
  const context = activeEditorNavigationContext();
  if (!context) return;

  const [{ readFileContent }] = await Promise.all([
    import("@/features/file-system/controllers/file-operations"),
  ]);
  const referencesActions = useReferencesStore.getState().actions;
  referencesActions.setIsLoading(true);
  useUIState.getState().setIsReferencesPopoverVisible(true);

  const lineContextCache = new Map<string, Map<number, string>>();
  const referenceLinesByFile = new Map<string, Set<number>>();
  for (const location of locations) {
    const lineNumbers = referenceLinesByFile.get(location.filePath) ?? new Set<number>();
    lineNumbers.add(location.line);
    referenceLinesByFile.set(location.filePath, lineNumbers);
  }

  const lineContextEntries = await Promise.all(
    Array.from(referenceLinesByFile, async ([filePath, lineNumbers]) => {
      let content = "";
      const buffer = context.bufferStore.buffers.find((candidate) => candidate.path === filePath);
      if (buffer && "content" in buffer && typeof buffer.content === "string") {
        content = buffer.content;
      } else {
        try {
          content = await readFileContent(filePath);
        } catch {
          content = "";
        }
      }
      return [filePath, getLineTextsFromContent(content, lineNumbers)] as const;
    }),
  );
  for (const [filePath, lines] of lineContextEntries) {
    lineContextCache.set(filePath, lines);
  }

  referencesActions.setReferences(
    {
      symbol,
      filePath: context.activeBuffer.path,
      line: context.editorState.cursorPosition.line,
      column: context.editorState.cursorPosition.column,
    },
    locations.map((location) => ({
      filePath: location.filePath,
      line: location.line,
      column: location.column,
      endLine: location.line,
      endColumn: location.column,
      lineContent: lineContextCache.get(location.filePath)?.get(location.line) || "",
    })),
  );
}

async function presentLspLocations(
  locations: LspLocation[],
  symbol: string,
  sourceBuffer: EditorContent,
): Promise<void> {
  const [{ readFileContent }, { filePathFromUri }] = await Promise.all([
    import("@/features/file-system/controllers/file-operations"),
    import("@/features/editor/lsp/workspace-edit"),
  ]);
  const bufferStore = useBufferStore.getState();
  const referenceLinesByFile = new Map<string, Set<number>>();

  for (const location of locations) {
    const filePath = filePathFromUri(location.uri);
    const lines = referenceLinesByFile.get(filePath) ?? new Set<number>();
    lines.add(location.range.start.line);
    referenceLinesByFile.set(filePath, lines);
  }

  const lineContextEntries = await Promise.all(
    Array.from(referenceLinesByFile, async ([filePath, lineNumbers]) => {
      const openBuffer = bufferStore.buffers.find((candidate) => candidate.path === filePath);
      let content =
        openBuffer && "content" in openBuffer && typeof openBuffer.content === "string"
          ? openBuffer.content
          : "";
      if (!content) {
        try {
          content = await readFileContent(filePath);
        } catch {
          content = "";
        }
      }
      return [filePath, getLineTextsFromContent(content, lineNumbers)] as const;
    }),
  );
  const lineContextCache = new Map(lineContextEntries);
  const referencesActions = useReferencesStore.getState().actions;
  referencesActions.setReferences(
    {
      symbol,
      filePath: sourceBuffer.path,
      line: useEditorStateStore.getState().cursorPosition.line,
      column: useEditorStateStore.getState().cursorPosition.column,
    },
    locations.map((location) => {
      const filePath = filePathFromUri(location.uri);
      return {
        filePath,
        line: location.range.start.line,
        column: location.range.start.character,
        endLine: location.range.end.line,
        endColumn: location.range.end.character,
        lineContent: lineContextCache.get(filePath)?.get(location.range.start.line) ?? "",
      };
    }),
  );
  useUIState.getState().setIsReferencesPopoverVisible(true);
}

async function goToActiveLspLocation(
  label: string,
  resolveLocations: (
    lspClient: LspNavigationClient,
    target: LspDocumentTarget,
    line: number,
    character: number,
  ) => Promise<LspLocation[] | null>,
  options: {
    requireLanguageServer?: boolean;
    feature?: string;
    commandArgs?: unknown;
    position?: { line: number; character: number };
    showMultipleResults?: boolean;
  } = {},
): Promise<void> {
  const [{ LspClient }, { readFileContent }] = await Promise.all([
    import("@/features/editor/lsp/lsp-client"),
    import("@/features/file-system/controllers/file-operations"),
  ]);

  const lspClient = LspClient.getInstance();
  const bufferStore = useBufferStore.getState();
  const activeBuffer = bufferStore.buffers.find((b) => b.id === bufferStore.activeBufferId);
  const editorState = useEditorStateStore.getState();
  const cursorPosition = editorState.cursorPosition;
  const requestLine = options.position?.line ?? cursorPosition.line;
  const requestCharacter = options.position?.character ?? cursorPosition.column;

  if (!activeBuffer || activeBuffer.type !== "editor" || !activeBuffer.path) return;
  const documentTarget = lspDocumentTargetForEditor(activeBuffer);

  if (options.requireLanguageServer !== false) {
    const readiness = await ensureNavigationLanguageServer(
      activeBuffer,
      options.feature ?? label,
      lspClient,
    );
    if (readiness !== "proceed") return;
  }

  const preResolvedLocations =
    label === "definition"
      ? definitionLocationsFromCommandArgs(options.commandArgs, {
          filePath: activeBuffer.path,
          line: requestLine,
          character: requestCharacter,
        })
      : undefined;
  const hasPreResolvedLocations = preResolvedLocations !== undefined;
  let locations = hasPreResolvedLocations
    ? preResolvedLocations
    : await resolveLocations(lspClient, documentTarget, requestLine, requestCharacter);

  if (
    (!locations || locations.length === 0) &&
    label === "definition" &&
    documentTarget.languageId === "java" &&
    !hasPreResolvedLocations
  ) {
    const workspaceRoot = useProjectStore.getState().rootFolderPath;
    if (workspaceRoot) {
      try {
        const fallback = await resolveLombokAccessorDefinition({
          source: activeBuffer.content,
          sourceFilePath: activeBuffer.path,
          workspaceRoot,
          line: requestLine,
          character: requestCharacter,
        });
        if (fallback) locations = [fallback];
      } catch (error) {
        logger.error("LombokNavigation", "Could not resolve generated accessor:", error);
      }
    }
  }

  if (!locations || locations.length === 0) {
    toast.info(
      getCurrentTranslator()("navigation.noTargetFound", {
        target: translateNavigationLabel(label),
      }),
    );
    return;
  }

  useJumpListStore.getState().actions.pushEntry({
    bufferId: activeBuffer.id,
    filePath: activeBuffer.path,
    line: cursorPosition.line,
    column: cursorPosition.column,
    offset: cursorPosition.offset,
    scrollTop: editorState.scrollTop,
    scrollLeft: editorState.scrollLeft,
  });

  if (navigationLocationPresentation(locations.length, options.showMultipleResults) === "list") {
    await presentLspLocations(locations, translateNavigationLabel(label), activeBuffer);
    return;
  }

  const target = locations[0];
  const openedBufferId = await openLspNavigationLocation({
    location: target,
    sourceFilePath: documentTarget.sessionFilePath ?? documentTarget.filePath,
    buffers: bufferStore.buffers,
    actions: bufferStore.actions,
    getVirtualDocument: (filePath, virtualUri) =>
      lspClient.getVirtualDocument(filePath, virtualUri),
    readFileContent,
  });
  if (!openedBufferId) {
    toast.info(
      getCurrentTranslator()("navigation.noTargetFound", {
        target: translateNavigationLabel(label),
      }),
    );
    return;
  }

  // Position the cursor at the target symbol. The go-to-line event is handled
  // per-editor with its own retry loop, which survives the async mount of a
  // newly opened buffer where a one-shot editorAPI call would silently miss.
  setTimeout(() => {
    window.dispatchEvent(
      new CustomEvent("menu-go-to-line", {
        detail: {
          line: target.range.start.line + 1,
          column: target.range.start.character + 1,
        },
      }),
    );
  }, 50);
}

export async function promptGoToLine(): Promise<void> {
  const t = getCurrentTranslator();
  const lineText = await showPromptDialog(t("navigation.goToLinePrompt"), {
    title: t("navigation.goToLine"),
    placeholder: t("navigation.lineNumber"),
  });
  if (!lineText) return;

  const line = Number.parseInt(lineText, 10);
  if (!Number.isFinite(line) || line < 1) {
    toast.warning(t("navigation.enterValidLineNumber"));
    return;
  }

  window.dispatchEvent(new CustomEvent("menu-go-to-line", { detail: { line } }));
}

export function openOutlinePicker(): void {
  if (!useSettingsStore.getState().settings.coreFeatures.outline) return;
  useUIState.getState().openCommandPaletteView("outline");
}

export function openOutlineSidebar(): void {
  if (!useSettingsStore.getState().settings.coreFeatures.outline) return;
  const uiState = useUIState.getState();
  uiState.setIsSidebarVisible(true);
  uiState.setActiveView("outline");
}

export async function goToDefinition(args?: unknown): Promise<void> {
  const springLocations = springLocationsForActiveFile("definition");
  if (springLocations.length === 1) {
    await navigateToSpringLocation(springLocations[0]);
    return;
  }
  if (springLocations.length > 1) {
    await presentSpringReferences(springLocations, springLocations[0]?.symbol || "Spring");
    return;
  }
  await goToActiveLspLocation(
    "definition",
    (lspClient, target, line, character) => lspClient.getDefinition(target, line, character),
    { feature: "definition", commandArgs: args },
  );
}

export async function goToImplementation(args?: unknown): Promise<void> {
  const markerCandidate =
    args && typeof args === "object" && "marker" in args
      ? (args as { marker?: unknown }).marker
      : undefined;
  const marker = normalizeJavaImplementationMarkers([markerCandidate])[0];
  const markerPosition = marker ? { line: marker.line, character: marker.utf16Column } : undefined;
  await goToActiveLspLocation(
    "implementation",
    (lspClient, target, line, character) =>
      marker
        ? lspClient.resolveJavaNavigation(target, marker)
        : lspClient.getImplementation(target, line, character),
    { feature: "implementation", position: markerPosition, showMultipleResults: true },
  );
}

/**
 * Navigates from an `@Override` method to the declaration it implements in the
 * parent interface or class. Uses the exact gutter marker position so the
 * cursor-position race that causes "click does nothing" cannot occur.
 *
 * JDTLS resolves `textDocument/definition` on an overriding method name to the
 * parent declaration, making this the correct LSP operation for "go to super".
 */
export async function goToSuperMethod(args?: unknown): Promise<void> {
  const markerCandidate =
    args && typeof args === "object" && "marker" in args
      ? (args as { marker?: unknown }).marker
      : undefined;
  const marker = normalizeJavaImplementationMarkers([markerCandidate])[0];
  const markerPosition = marker ? { line: marker.line, character: marker.utf16Column } : undefined;
  await goToActiveLspLocation(
    "definition",
    (lspClient, target, line, character) =>
      marker
        ? lspClient.resolveJavaNavigation(target, marker)
        : lspClient.getDefinition(target, line, character),
    { feature: "definition", position: markerPosition, showMultipleResults: true },
  );
}

export async function goToTypeDefinition(): Promise<void> {
  await goToActiveLspLocation(
    "type definition",
    (lspClient, target, line, character) => lspClient.getTypeDefinition(target, line, character),
    { feature: "typeDefinition" },
  );
}

export async function goToReferences(): Promise<void> {
  const [{ LspClient }, { readFileContent }, { filePathFromUri }] = await Promise.all([
    import("@/features/editor/lsp/lsp-client"),
    import("@/features/file-system/controllers/file-operations"),
    import("@/features/editor/lsp/workspace-edit"),
  ]);

  const lspClient = LspClient.getInstance();
  const bufferStore = useBufferStore.getState();
  const activeBuffer = bufferStore.buffers.find((b) => b.id === bufferStore.activeBufferId);
  const cursorPosition = useEditorStateStore.getState().cursorPosition;

  if (!activeBuffer?.path) return;

  const springLocations = springLocationsForActiveFile("references").filter(
    (location) =>
      !isCurrentNavigationTarget(
        activeBuffer.path,
        cursorPosition.line,
        location.filePath,
        location.line,
      ),
  );
  if (springLocations.length === 1) {
    await navigateToSpringLocation(springLocations[0]);
    return;
  }
  if (springLocations.length > 1) {
    await presentSpringReferences(springLocations, springLocations[0]?.symbol || "Spring");
    return;
  }

  if (activeBuffer.type !== "editor") return;
  const documentTarget = lspDocumentTargetForEditor(activeBuffer);
  if ((await ensureNavigationLanguageServer(activeBuffer, "references", lspClient)) !== "proceed") {
    return;
  }

  const currentLine = getLineTextFromContent(editorAPI.getContent(), cursorPosition.line);
  const wordMatch = currentLine.slice(0, cursorPosition.column + 1).match(/[\w$]+$/);
  const wordEnd = currentLine.slice(cursorPosition.column).match(/^[\w$]*/);
  const symbol = (wordMatch?.[0] || "") + (wordEnd?.[0]?.slice(1) || "");

  const references = await lspClient.getReferences(
    documentTarget,
    cursorPosition.line,
    cursorPosition.column,
  );

  const origin = {
    symbol: symbol || "symbol",
    filePath: activeBuffer.path,
    line: cursorPosition.line,
    column: cursorPosition.column,
  };

  if (!references || references.length === 0) {
    toast.info(getCurrentTranslator()("navigation.noReferencesFound"));
    return;
  }

  const otherReferences = references.filter((reference) => {
    const filePath = filePathFromUri(reference.uri);
    return !isCurrentNavigationTarget(
      activeBuffer.path,
      cursorPosition.line,
      filePath,
      reference.range.start.line,
    );
  });

  if (otherReferences.length === 0) {
    toast.info(getCurrentTranslator()("navigation.noOtherReferencesFound"));
    return;
  }

  if (otherReferences.length === 1) {
    const target = otherReferences[0];
    await goToActiveLspLocation("reference", async () => [target], {
      requireLanguageServer: false,
    });
    return;
  }

  const referencesActions = useReferencesStore.getState().actions;
  referencesActions.setIsLoading(true);
  useUIState.getState().setIsReferencesPopoverVisible(true);

  const lineContextCache = new Map<string, Map<number, string>>();
  const referenceLinesByFile = new Map<string, Set<number>>();

  for (const ref of otherReferences) {
    const filePath = filePathFromUri(ref.uri);
    const lineNumbers = referenceLinesByFile.get(filePath) ?? new Set<number>();
    lineNumbers.add(ref.range.start.line);
    referenceLinesByFile.set(filePath, lineNumbers);
  }

  const lineContextEntries = await Promise.all(
    Array.from(referenceLinesByFile, async ([filePath, lineNumbers]) => {
      let content = "";
      const buffer = bufferStore.buffers.find((b) => b.path === filePath);

      if (buffer && "content" in buffer && typeof buffer.content === "string") {
        content = buffer.content;
      } else {
        try {
          content = await readFileContent(filePath);
        } catch {
          content = "";
        }
      }

      return [filePath, getLineTextsFromContent(content, lineNumbers)] as const;
    }),
  );

  for (const [filePath, lines] of lineContextEntries) {
    lineContextCache.set(filePath, lines);
  }

  const converted = otherReferences.map((ref) => {
    const filePath = filePathFromUri(ref.uri);
    const fileLines = lineContextCache.get(filePath);
    return {
      filePath,
      line: ref.range.start.line,
      column: ref.range.start.character,
      endLine: ref.range.end.line,
      endColumn: ref.range.end.character,
      lineContent: fileLines?.get(ref.range.start.line) || "",
    };
  });

  referencesActions.setReferences(origin, converted);
}

export async function goBack(): Promise<void> {
  const bufferStore = useBufferStore.getState();
  const editorState = useEditorStateStore.getState();
  const activeBufferId = bufferStore.activeBufferId;
  const activeBuffer = bufferStore.buffers.find((b) => b.id === activeBufferId);

  const currentPosition =
    activeBufferId && activeBuffer?.path
      ? {
          bufferId: activeBufferId,
          filePath: activeBuffer.path,
          line: editorState.cursorPosition.line,
          column: editorState.cursorPosition.column,
          offset: editorState.cursorPosition.offset,
          scrollTop: editorState.scrollTop,
          scrollLeft: editorState.scrollLeft,
        }
      : undefined;

  const entry = useJumpListStore.getState().actions.goBack(currentPosition);
  if (entry) {
    await navigateToJumpEntry(entry);
  }
}

export async function goForward(): Promise<void> {
  const entry = useJumpListStore.getState().actions.goForward();
  if (entry) {
    await navigateToJumpEntry(entry);
  }
}
