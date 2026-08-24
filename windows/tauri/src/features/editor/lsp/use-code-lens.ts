import { useCallback, useEffect, useRef, useState } from "react";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { isDocumentFeatureAvailable, LspClient } from "./lsp-client";
import { lspDocumentTargetForEditorPath } from "./lsp-document-target";
import { useLspStore } from "./stores/lsp.store";

export interface CodeLensItem {
  line: number;
  title: string;
  command?: string;
  arguments?: unknown[];
}

export const useCodeLens = (filePath: string | undefined, enabled: boolean) => {
  const [lenses, setLenses] = useState<CodeLensItem[]>([]);
  const requestIdRef = useRef(0);
  const lspStatusRevision = useLspStore((state) => {
    const { status, activeWorkspaces, supportedLanguages, documentRevision } = state.lspStatus;
    return `${status}:${activeWorkspaces.join("|")}:${supportedLanguages?.join("|") ?? ""}:${documentRevision}`;
  });

  const fetchLenses = useCallback(async () => {
    if (!filePath || !enabled) {
      setLenses([]);
      return;
    }

    const id = ++requestIdRef.current;
    const lspClient = LspClient.getInstance();
    const target = lspDocumentTargetForEditorPath(useBufferStore.getState().buffers, filePath);
    if (
      !target ||
      !isDocumentFeatureAvailable(lspClient.getDocumentAvailability(target, "codeLens")) ||
      (!target.documentUri && !lspClient.isDocumentOpen(target.filePath))
    ) {
      setLenses([]);
      return;
    }

    const result = await lspClient.getCodeLens(target);

    if (id !== requestIdRef.current) return;
    setLenses(result);
  }, [filePath, enabled]);

  useEffect(() => {
    void fetchLenses();
  }, [fetchLenses, lspStatusRevision]);

  return lenses;
};
