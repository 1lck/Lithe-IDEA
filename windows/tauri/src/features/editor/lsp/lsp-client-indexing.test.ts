import { expect, spyOn, test } from "bun:test";
import * as indexing from "@/features/file-explorer/stores/workspace-indexing";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import * as adapter from "@/platform/lsp-core-adapter";
import { LspClient } from "./lsp-client";

test.each([
  ["C:/main/src/main.go", "C:/main", "src"],
  ["D:/added/src/main.go", "D:/added", "src"],
  ["d:\\ADDED\\nested\\SRC\\main.go", "D:/added/nested", "SRC"],
  ["//?/D:/added/main.go", "D:/added", "."],
  ["E:/outside/main.go", undefined, undefined],
] as const)("LSP indexing uses the file's owning root: %s", async (file, owner, parent) => {
  const workspaceId = "indexing-lsp-fixture";
  const scope = { workspaceId, root: "C:/main" };
  const store = useFileSystemStore.getStore(workspaceId);
  store.setState({
    rootFolderPath: scope.root,
    workspaceFolders: [
      { path: "D:/added", name: "added", isPrimary: false },
      { path: "D:/added/nested", name: "nested", isPrimary: false },
    ],
  });
  const configure = spyOn(indexing, "configureWorkspaceIndexing").mockResolvedValue({
    revision: 1,
    excludedDirectories: {},
    gitIgnoreFailed: false,
  });
  const snapshot = spyOn(adapter, "getLspSessionSnapshot").mockReturnValue(null);
  const client = Object.create(LspClient.prototype) as LspClient;
  const starts: unknown[] = [];
  Object.assign(client, {
    fileAttachmentIds: new Map(),
    fileStartTasks: new Map(),
    startFileAttachment: async (_file: string, receivedScope: unknown) => {
      starts.push(receivedScope);
      return { kind: "attached", attachmentId: "fixture" };
    },
  });
  try {
    expect((await client.startForFile(file, scope)).kind).toBe("attached");
    expect(starts).toEqual([scope]);
    if (owner) expect(configure).toHaveBeenCalledWith(owner, [parent], false, workspaceId);
    else expect(configure).not.toHaveBeenCalled();
    if (owner) {
      configure.mockResolvedValue({
        revision: 2,
        excludedDirectories: { [parent!]: "manual" },
        gitIgnoreFailed: false,
      });
      expect(await client.startForFile(file, scope)).toEqual({
        kind: "cancelled",
        reason: "excluded",
      });
      expect(starts).toHaveLength(1);
      configure.mockImplementation(async () => {
        workspaceRuntimeRegistry.removeWorkspace(workspaceId);
        return { revision: 3, excludedDirectories: {}, gitIgnoreFailed: false };
      });
      expect(await client.startForFile(file, scope)).toEqual({
        kind: "cancelled",
        reason: "superseded",
      });
      expect(workspaceRuntimeRegistry.hasWorkspace(workspaceId)).toBe(false);
    }
  } finally {
    configure.mockRestore();
    snapshot.mockRestore();
    workspaceRuntimeRegistry.removeWorkspace(workspaceId);
  }
});
