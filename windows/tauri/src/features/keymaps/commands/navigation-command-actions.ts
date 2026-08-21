import { editorAPI } from "@/features/editor/extensions/api";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { useEditorStateStore } from "@/features/editor/stores/state.store";
import { useJumpListStore } from "@/features/editor/stores/jump-list.store";
import { navigateToJumpEntry } from "@/features/editor/utils/jump-navigation";
import {
  calculateOffsetFromContentPosition,
  getLineTextFromContent,
  getLineTextsFromContent,
} from "@/features/editor/utils/position";
import { useReferencesStore } from "@/features/references/stores/references.store";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { languageIdForEditorFile } from "@/features/editor/lsp/built-in-language-support";
import { languageServerUnavailableMessage } from "@/features/editor/lsp/language-server-navigation";
import { resolveLombokAccessorDefinition } from "@/features/editor/lsp/lombok-accessor-navigation";
import { openLspNavigationLocation } from "@/features/editor/lsp/navigation-target";
import {
  lspDocumentTargetForEditor,
  type LspDocumentTarget,
  type LspDocumentTargetInput,
} from "@/features/editor/lsp/lsp-document-target";
import { definitionLocationsFromCommandArgs } from "@/features/editor/lsp/definition-navigation-hint";
import type { LspDocumentAvailability, LspLocation } from "@/features/editor/lsp/lsp-client";
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
  getDocumentAvailability: (
    target: LspDocumentTargetInput,
    feature?: string,
  ) => LspDocumentAvailability;
  getVirtualDocument: (filePath: string, virtualUri: string) => Promise<string | null>;
};

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

function unavailableLanguageServerToast(
  buffer: EditorContent,
  feature: string,
  lspClient: Pick<LspNavigationClient, "getDocumentAvailability">,
): string | null {
  const availability = lspClient.getDocumentAvailability(
    lspDocumentTargetForEditor(buffer),
    feature,
  );
  const globalStatus = useLspStore.getState().lspStatus;
  return languageServerUnavailableMessage({
    languageId: availability.languageId,
    status: availability.hasSession ? availability.status : globalStatus.status,
    lastError: availability.hasSession ? undefined : globalStatus.lastError,
    hasSession: availability.hasSession,
    ready: availability.ready,
    featuresKnown: availability.featuresKnown,
    supportsFeature: availability.supportsFeature,
    featureLabel: feature,
  });
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
  context.bufferStore.actions.openReferencesBuffer();

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

async function goToActiveLspLocation(
  label: string,
  resolveLocations: (
    lspClient: LspNavigationClient,
    target: LspDocumentTarget,
    line: number,
    character: number,
  ) => Promise<LspLocation[] | null>,
  options: { requireLanguageServer?: boolean; feature?: string; commandArgs?: unknown } = {},
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

  if (!activeBuffer || activeBuffer.type !== "editor" || !activeBuffer.path) return;
  const documentTarget = lspDocumentTargetForEditor(activeBuffer);

  if (options.requireLanguageServer !== false) {
    const unavailable = unavailableLanguageServerToast(
      activeBuffer,
      options.feature ?? label,
      lspClient,
    );
    if (unavailable) {
      toast.error(unavailable);
      return;
    }
  }

  const preResolvedLocations =
    label === "definition"
      ? definitionLocationsFromCommandArgs(options.commandArgs, {
          filePath: activeBuffer.path,
          line: cursorPosition.line,
          character: cursorPosition.column,
        })
      : undefined;
  const hasPreResolvedLocations = preResolvedLocations !== undefined;
  let locations = hasPreResolvedLocations
    ? preResolvedLocations
    : await resolveLocations(lspClient, documentTarget, cursorPosition.line, cursorPosition.column);

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
          line: cursorPosition.line,
          character: cursorPosition.column,
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

  setTimeout(() => {
    const content = editorAPI.getContent();
    const offset = calculateOffsetFromContentPosition(
      content,
      target.range.start.line,
      target.range.start.character,
    );

    editorAPI.setCursorPosition({
      line: target.range.start.line,
      column: target.range.start.character,
      offset,
    });
  }, 100);
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

export async function goToImplementation(): Promise<void> {
  await goToActiveLspLocation(
    "implementation",
    (lspClient, target, line, character) => lspClient.getImplementation(target, line, character),
    { feature: "implementation" },
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
  const unavailable = unavailableLanguageServerToast(activeBuffer, "references", lspClient);
  if (unavailable) {
    toast.error(unavailable);
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
  bufferStore.actions.openReferencesBuffer();

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
