import type { EditorContent } from "@/features/panes/types/pane-content.types";
import "../stores/buffer-history-tracking";
import "@/features/file-system/controllers/platform";
import { installHappyDom } from "@/test-utils/happy-dom";
import { afterEach, beforeEach, expect, spyOn, test } from "bun:test";
import * as native from "@/platform/tauri-core";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { useBufferStore } from "../stores/buffer.store";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { applyWorkspaceEdit } from "./workspace-edit";
const workspace = { id: "edit-race", name: "Edit race" };
let restore: () => void;
beforeEach(() => { restore = installHappyDom(); workspaceRuntimeRegistry.resetForTests(); workspaceRuntimeRegistry.activateWorkspace(workspace, "ready"); });
afterEach(() => { workspaceRuntimeRegistry.resetForTests(); restore(); });
for (const mutation of ["typing", "closed", "workspace"] as const) {
 test("rejects delayed edits after " + mutation + " without overwriting input", async () => {
  const store = useBufferStore.getStore(workspace.id);
  const buffer: EditorContent = { id: "one", type: "editor", path: "C:/work/a.ts", name: "a.ts", content: "abc", savedContent: "abc", isVirtual: false, isDirty: false, isPinned: false, isPreview: false, isActive: true, tokens: [], contentRevision: 1 };
  store.setState({ buffers: [buffer] });
  useFileSystemStore.getStore(workspace.id).setState({ rootFolderPath: "C:/work" });
  let release!: (value: {text:string}) => void; let entered!: () => void;
  const started = new Promise<void>(r => { entered = r; });
  const pending = new Promise<{text:string}>(r => { release = r; });
  const invoke = spyOn(native, "invoke").mockImplementation(async (command, args) => {
    if(command === "lsp.planWorkspaceEdit") {
      const changes = (args as { changes: Record<string, unknown[]> }).changes;
      return { rejection: null, targets: Object.entries(changes).map(([path, edits]) => ({ path, effect: "updateDocument", edits })) } as never;
    }
    if(command === "lsp.applyTextEdits") { entered(); return pending as never; } return undefined as never; });
  const operation = applyWorkspaceEdit({ changes: { "C:/work/a.ts": [{ range: { start: {line:0,character:0}, end: {line:0,character:1} }, newText:"X" }] } });
  const outcome = operation.catch(error => error);
  try {
   await started;
   if(mutation === "typing") store.setState({buffers:[{...buffer,content:"abc!",contentRevision:2}]});
   if(mutation === "closed") store.setState({buffers:[]});
   if(mutation === "workspace") workspaceRuntimeRegistry.activateWorkspace({id:"other",name:"Other"}, "ready");
   release({text:"Xbc"}); expect(await outcome).toBeInstanceOf(Error);
   expect((store.getState().buffers[0] as EditorContent | undefined)?.content).toBe(mutation === "closed" ? undefined : mutation === "typing" ? "abc!" : "abc");
  } finally { release({text:"Xbc"}); await operation.catch(()=>{}); invoke.mockRestore(); }
 });
}
