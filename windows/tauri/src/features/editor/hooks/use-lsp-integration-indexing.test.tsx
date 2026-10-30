import { expect, spyOn, test } from "bun:test";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { createPaneContent } from "@/features/editor/stores/buffer-content-factory";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { LspClient } from "@/features/editor/lsp/lsp-client";
import * as deferred from "@/features/editor/lsp/deferred-lsp-work";
import * as indexing from "@/features/file-explorer/stores/workspace-indexing";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import * as adapter from "@/platform/lsp-core-adapter";
import { installHappyDom } from "@/test-utils/happy-dom";
import { useLspIntegration } from "./use-lsp-integration";

test("adding and removing a nested root reevaluates an open document's LSP policy", async () => {
  const restoreDom = installHappyDom();
  const environment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
  const previousAct = environment.IS_REACT_ACT_ENVIRONMENT;
  const previousWorkspace = workspaceRuntimeRegistry.getActiveWorkspaceId();
  const workspaceId = "lsp-root-membership-fixture";
  const filePath = "C:/main/nested/src/Main.java";
  workspaceRuntimeRegistry.activateWorkspace({ id: workspaceId, name: "fixture" }, "ready");
  const store = useFileSystemStore.getStore(workspaceId);
  store.setState({ rootFolderPath: "C:/main", workspaceFolders: [] });
  const buffers = useBufferStore.getStore(workspaceId);
  buffers.setState({
    buffers: [
      createPaneContent("fixture", {
        type: "editor",
        name: "Main.java",
        path: filePath,
        content: "class Main {}",
      }),
    ],
  });
  const scheduled = new Set<() => void>();
  const defer = spyOn(deferred, "deferUntilAfterNextPaint").mockImplementation((work) => {
    scheduled.add(work);
    return () => {
      scheduled.delete(work);
    };
  });
  const configure = spyOn(indexing, "configureWorkspaceIndexing").mockImplementation(
    async (root): Promise<indexing.IndexingStatus> => ({
      revision: 1,
      excludedDirectories: root.endsWith("nested") ? { src: "manual" } : {},
      gitIgnoreFailed: false,
    }),
  );
  const snapshot = spyOn(adapter, "getLspSessionSnapshot").mockReturnValue(null);
  const events: string[] = [];
  const client = Object.create(LspClient.prototype) as LspClient;
  Object.assign(client, {
    fileAttachmentIds: new Map(),
    fileStartTasks: new Map(),
    startFileAttachment: async () => ({ kind: "attached", attachmentId: "fixture" }),
    notifyDocumentOpen: async () => {
      events.push("open");
    },
    notifyDocumentClose: async () => {
      events.push("close");
    },
    stopForFile: async () => {
      events.push("stop");
    },
  });
  const instance = spyOn(LspClient, "getInstance").mockReturnValue(client);
  const host = document.createElement("div");
  const root = createRoot(host);
  function Probe() {
    useLspIntegration({ filePath });
    return null;
  }
  const flush = async () =>
    act(async () => {
      const ready = [...scheduled];
      scheduled.clear();
      for (const work of ready) work();
    });
  try {
    environment.IS_REACT_ACT_ENVIRONMENT = true;
    document.body.append(host);
    await act(async () => root.render(<Probe />));
    await flush();
    expect(events).toEqual(["open"]);
    await act(async () =>
      store.setState({
        workspaceFolders: [{ path: "C:/main/nested", name: "nested", isPrimary: false }],
      }),
    );
    await flush();
    expect(events).toEqual(["open", "close", "stop"]);
    expect(configure).toHaveBeenLastCalledWith("C:/main/nested", ["src"]);
    await act(async () => store.setState({ workspaceFolders: [] }));
    await flush();
    expect(events).toEqual(["open", "close", "stop", "open"]);
  } finally {
    buffers.setState({ buffers: [] });
    try {
      await act(async () => root.unmount());
    } finally {
      scheduled.clear();
      defer.mockRestore();
      configure.mockRestore();
      snapshot.mockRestore();
      instance.mockRestore();
      host.remove();
      workspaceRuntimeRegistry.removeWorkspace(workspaceId);
      workspaceRuntimeRegistry.activateWorkspace({ id: previousWorkspace, name: "restored" });
      if (previousAct === undefined) delete environment.IS_REACT_ACT_ENVIRONMENT;
      else environment.IS_REACT_ACT_ENVIRONMENT = previousAct;
      restoreDom();
    }
  }
});
