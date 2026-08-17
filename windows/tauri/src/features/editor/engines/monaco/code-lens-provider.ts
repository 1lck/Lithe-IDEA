import {
  Emitter,
  Range as MonacoRange,
  Uri,
  editor as monacoEditor,
  languages,
} from "monaco-editor";
import type * as Monaco from "monaco-editor";
import { toast } from "sonner";
import { isEditorLspSupported } from "@/features/editor/lsp/built-in-language-support";
import { LspClient } from "@/features/editor/lsp/lsp-client";
import { useLspStore } from "@/features/editor/lsp/stores/lsp.store";
import { filePathFromUri } from "@/features/editor/lsp/workspace-edit";
import { MONACO_HIGHLIGHT_LANGUAGE_IDS } from "./language";
import { filePathFromLitheModelUri } from "./model-uri";

const EXECUTE_LSP_CODE_LENS_COMMAND = "lithe.executeLspCodeLens";
const SHOW_REFERENCES_COMMAND = "editor.action.showReferences";

interface LspCodeLens {
  line: number;
  title: string;
  command?: string;
  arguments?: unknown[];
}

interface ExecuteLspCodeLensPayload {
  filePath: string;
  lens: LspCodeLens;
}

interface LspPosition {
  line: number;
  character: number;
}

interface LspLocation {
  uri: string;
  range: {
    start: LspPosition;
    end: LspPosition;
  };
}

let codeLensProviderRegistered = false;

function filePathFromModel(model: Monaco.editor.ITextModel): string {
  if (model.uri.scheme === "file") {
    return filePathFromUri(model.uri.toString());
  }

  if (model.uri.scheme !== "lithe") {
    return decodeURIComponent(model.uri.path);
  }

  return filePathFromLitheModelUri(model.uri.path, model.uri.query);
}

function isLspPosition(value: unknown): value is LspPosition {
  if (!value || typeof value !== "object") return false;
  const position = value as Partial<LspPosition>;
  return typeof position.line === "number" && typeof position.character === "number";
}

function isLspLocation(value: unknown): value is LspLocation {
  if (!value || typeof value !== "object") return false;
  const location = value as Partial<LspLocation>;
  return (
    typeof location.uri === "string" &&
    !!location.range &&
    isLspPosition(location.range.start) &&
    isLspPosition(location.range.end)
  );
}

function toMonacoPosition(position: LspPosition): Monaco.IPosition {
  return {
    lineNumber: position.line + 1,
    column: position.character + 1,
  };
}

function toMonacoLocation(location: LspLocation): Monaco.languages.Location {
  return {
    uri: Uri.parse(location.uri),
    range: new MonacoRange(
      location.range.start.line + 1,
      location.range.start.character + 1,
      location.range.end.line + 1,
      location.range.end.character + 1,
    ),
  };
}

function toShowReferencesArguments(argumentsValue: unknown[] | undefined): unknown[] | null {
  const [resource, position, locations, ...rest] = argumentsValue ?? [];
  if (
    typeof resource !== "string" ||
    !isLspPosition(position) ||
    !Array.isArray(locations) ||
    !locations.every(isLspLocation)
  ) {
    return null;
  }

  return [
    Uri.parse(resource),
    toMonacoPosition(position),
    locations.map(toMonacoLocation),
    ...rest,
  ];
}

export function toMonacoCodeLens(
  filePath: string,
  lens: LspCodeLens,
): Monaco.languages.CodeLens | null {
  if (!lens.command) return null;

  const range = new MonacoRange(lens.line + 1, 1, lens.line + 1, 1);
  if (lens.command === SHOW_REFERENCES_COMMAND) {
    const referencesArguments = toShowReferencesArguments(lens.arguments);
    if (referencesArguments) {
      return {
        range,
        command: {
          id: SHOW_REFERENCES_COMMAND,
          title: lens.title,
          arguments: referencesArguments,
        },
      };
    }
  }

  return {
    range,
    command: {
      id: EXECUTE_LSP_CODE_LENS_COMMAND,
      title: lens.title,
      arguments: [{ filePath, lens } satisfies ExecuteLspCodeLensPayload],
    },
  };
}

export function registerMonacoCodeLensProvider(): void {
  if (codeLensProviderRegistered) return;
  codeLensProviderRegistered = true;

  const lspClient = LspClient.getInstance();
  const codeLensesChanged = new Emitter<Monaco.languages.CodeLensProvider>();
  const provider: Monaco.languages.CodeLensProvider = {
    onDidChange: codeLensesChanged.event,
    async provideCodeLenses(model, token) {
      const filePath = filePathFromModel(model);
      if (
        !filePath ||
        !isEditorLspSupported(filePath) ||
        !lspClient.getActiveServerEntryForFile(filePath) ||
        !lspClient.isDocumentOpen(filePath)
      ) {
        return { lenses: [] };
      }

      const lenses = await lspClient.getCodeLens(filePath);
      if (token.isCancellationRequested) return { lenses: [] };

      return {
        lenses: lenses
          .map((lens) => toMonacoCodeLens(filePath, lens))
          .filter((lens): lens is Monaco.languages.CodeLens => lens !== null),
      };
    },
  };
  useLspStore.subscribe((state, previousState) => {
    const currentStatus = state.lspStatus;
    const previousStatus = previousState.lspStatus;
    if (
      currentStatus.status !== previousStatus.status ||
      currentStatus.documentRevision !== previousStatus.documentRevision
    ) {
      codeLensesChanged.fire(provider);
    }
  });

  monacoEditor.addCommand({
    id: EXECUTE_LSP_CODE_LENS_COMMAND,
    run: (_accessor, payload: ExecuteLspCodeLensPayload | undefined) => {
      if (!payload?.filePath || !payload.lens.command) return;

      void lspClient
        .applyCodeAction(payload.filePath, {
          title: payload.lens.title,
          command: payload.lens.command,
          arguments: payload.lens.arguments ?? [],
        })
        .then((result) => {
          if (!result.applied) {
            toast.error(result.reason || `Failed to run ${payload.lens.title}`);
          }
        });
    },
  });

  languages.registerCodeLensProvider(Array.from(MONACO_HIGHLIGHT_LANGUAGE_IDS), provider);
}
