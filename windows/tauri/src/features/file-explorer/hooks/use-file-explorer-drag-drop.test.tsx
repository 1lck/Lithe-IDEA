import { afterEach, beforeEach, expect, spyOn, test } from "bun:test";
import { mockIPC, clearMocks } from "@tauri-apps/api/mocks";
import { act, type MouseEvent as ReactMouseEvent } from "react";
import { createRoot, type Root } from "react-dom/client";
import * as capabilities from "@/config/backend-capabilities";
import type { FileEntry } from "@/features/file-system/types/app.types";
import { installHappyDom } from "@/test-utils/happy-dom";
import { useFileExplorerDragDrop } from "./use-file-explorer-drag-drop";

const workspace = "C:/fixture/project";
const files: FileEntry[] = ["a.ts", "b.ts"].map((name) => ({
  path: `${workspace}/${name}`,
  name,
  isDir: false,
}));
let restoreDom: () => void;
let container: HTMLDivElement;
let root: Root;
let releaseMove: () => void;
let releasePreflight: () => void;
let releaseOwnerSync: () => void;
let nativeMoves: Array<[string, string]>;
let synchronized: Array<[string, string]>;
let errors: string[];
let previousAct: boolean | undefined;
let previousCustomEvent: typeof CustomEvent;
const actGlobal = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };

function DragSource({
  rootPath = workspace,
  moved = synchronize,
  entries = files,
}: {
  rootPath?: string;
  moved?: (from: string, to: string) => void | Promise<void>;
  entries?: FileEntry[];
}) {
  const { dragState, startDrag } = useFileExplorerDragDrop(rootPath, moved, undefined, (error) =>
    errors.push(error),
  );
  return (
    <button
      data-dragging={dragState.isDragging}
      data-over={dragState.dragOverPath}
      onMouseDown={(event: ReactMouseEvent) => startDrag(event, entries[0], entries)}
    >
      drag
    </button>
  );
}

function synchronize(from: string, to: string) {
  synchronized.push([from, to]);
}

beforeEach(() => {
  restoreDom = installHappyDom();
  previousCustomEvent = globalThis.CustomEvent;
  globalThis.CustomEvent = window.CustomEvent;
  previousAct = actGlobal.IS_REACT_ACT_ENVIRONMENT;
  actGlobal.IS_REACT_ACT_ENVIRONMENT = true;
  nativeMoves = [];
  synchronized = [];
  errors = [];
  releaseMove = () => {};
  releasePreflight = () => {};
  releaseOwnerSync = () => {};
  mockIPC((command, args) => {
    if (command === "plugin:fs|read_dir") return [];
    if (command === "move_file") {
      const payload = args as { sourcePath: string; targetPath: string };
      nativeMoves.push([payload.sourcePath, payload.targetPath]);
      return new Promise<void>((resolve) => {
        releaseMove = resolve;
      });
    }
    throw new Error(`Unexpected native call: ${command}`);
  });
  container = document.createElement("div");
  const target = document.createElement("div");
  target.className = "file-tree-container";
  target.setAttribute("data-file-path", `${workspace}/archive`);
  target.setAttribute("data-is-dir", "true");
  container.append(target);
  document.body.append(container);
  Object.defineProperty(document, "elementFromPoint", { configurable: true, value: () => target });
  const host = document.createElement("div");
  container.append(host);
  root = createRoot(host);
});

afterEach(async () => {
  await act(async () => {
    root.unmount();
    releasePreflight();
    releaseMove();
    releaseOwnerSync();
  });
  container.remove();
  clearMocks();
  globalThis.CustomEvent = previousCustomEvent;
  restoreDom();
  if (previousAct === undefined) delete actGlobal.IS_REACT_ACT_ENVIRONMENT;
  else actGlobal.IS_REACT_ACT_ENVIRONMENT = previousAct;
});

async function dropFiles(
  rootPath = workspace,
  entries = files,
  target = `${workspace}/archive`,
  moved: (from: string, to: string) => void | Promise<void> = synchronize,
) {
  document.elementFromPoint(0, 0)!.setAttribute("data-file-path", target);
  await act(async () => root.render(<DragSource rootPath={rootPath} entries={entries} moved={moved} />));
  await act(async () =>
    container
      .querySelector("button")!
      .dispatchEvent(new window.MouseEvent("mousedown", { bubbles: true })),
  );
  expect(container.querySelector("button")!.dataset.dragging).toBe("true");
  await act(async () =>
    document
      .elementFromPoint(0, 0)!
      .dispatchEvent(new window.MouseEvent("mousemove", { bubbles: true })),
  );
  expect(container.querySelector("button")!.dataset.over).toBe(target);
  await act(async () =>
    document
      .elementFromPoint(0, 0)!
      .dispatchEvent(new window.MouseEvent("mouseup", { bubbles: true })),
  );
}

async function beginMove() {
  await dropFiles();
  expect(nativeMoves).toHaveLength(1);
  expect(synchronized).toEqual([]);
}

test("a successful native move reconciles its owner after the Project pane unmounts", async () => {
  await beginMove();
  await act(async () => root.render(null));
  await act(async () => releaseMove());
  expect(synchronized).toEqual(nativeMoves);
  expect(nativeMoves).toHaveLength(1);
  expect(errors).toEqual([]);
});

test("switching workspace reconciles only the successful item with the original owner", async () => {
  await beginMove();
  const otherWorkspace: Array<[string, string]> = [];
  await act(async () =>
    root.render(
      <DragSource
        rootPath="C:/fixture/other"
        moved={(from, to) => {
          otherWorkspace.push([from, to]);
        }}
      />,
    ),
  );
  await act(async () => releaseMove());
  expect(synchronized).toEqual(nativeMoves);
  expect(nativeMoves).toHaveLength(1);
  expect(otherWorkspace).toEqual([]);
  expect(errors).toEqual([]);
});

test("returning to a workspace stops its previous batch after the successful move", async () => {
  await beginMove();
  await act(async () => root.render(<DragSource rootPath="C:/fixture/other" />));
  await act(async () => root.render(<DragSource />));
  await act(async () => releaseMove());
  expect(nativeMoves).toHaveLength(1);
  expect(nativeMoves[0]?.[0]).toBe(files[0].path);
  expect(synchronized).toEqual(nativeMoves);
  expect(errors).toEqual([]);
});

test("rerendering the same workspace still completes its batch", async () => {
  await beginMove();
  await act(async () => root.render(<DragSource />));
  await act(async () => releaseMove());
  expect(nativeMoves).toHaveLength(2);
  expect(synchronized).toEqual(nativeMoves.slice(0, 1));
  await act(async () => releaseMove());
  expect(synchronized).toEqual(nativeMoves);
  expect(errors).toEqual([]);
});

test("returning to a workspace during preflight does not start the old batch", async () => {
  mockIPC((command, args) => {
    if (command === "plugin:fs|read_dir")
      return new Promise<[]>((resolve) => {
        releasePreflight = () => resolve([]);
      });
    if (command === "move_file") {
      const payload = args as { sourcePath: string; targetPath: string };
      nativeMoves.push([payload.sourcePath, payload.targetPath]);
      return;
    }
    throw new Error(`Unexpected native call: ${command}`);
  });
  await dropFiles();
  expect(nativeMoves).toEqual([]);
  await act(async () => root.render(<DragSource rootPath="C:/fixture/other" />));
  await act(async () => root.render(<DragSource />));
  await act(async () => releasePreflight());
  expect(nativeMoves).toEqual([]);
  expect(synchronized).toEqual([]);
  expect(errors).toEqual([]);
});

test("returning during owner synchronization stops the remaining moves", async () => {
  const moved = (from: string, to: string) => {
    synchronize(from, to);
    return new Promise<void>((resolve) => {
      releaseOwnerSync = resolve;
    });
  };
  await dropFiles(workspace, files, `${workspace}/archive`, moved);
  await act(async () => releaseMove());
  expect(synchronized).toEqual(nativeMoves);
  await act(async () => root.render(<DragSource rootPath="C:/fixture/other" />));
  await act(async () => root.render(<DragSource />));
  await act(async () => releaseOwnerSync());
  expect(nativeMoves).toHaveLength(1);
  expect(errors).toEqual([]);
});

test("a failed old batch does not clear a new drag after returning to its workspace", async () => {
  mockIPC((command) => {
    if (command === "plugin:fs|read_dir") return [];
    if (command === "move_file")
      return new Promise<void>((_resolve, reject) => {
        releaseMove = () => reject(new Error("Move failed"));
      });
    throw new Error(`Unexpected native call: ${command}`);
  });
  const logged = spyOn(console, "error").mockImplementation(() => {});
  try {
    await dropFiles();
    await act(async () => root.render(<DragSource rootPath="C:/fixture/other" />));
    await act(async () => root.render(<DragSource />));
    await act(async () =>
      container
        .querySelector("button")!
        .dispatchEvent(new window.MouseEvent("mousedown", { bubbles: true })),
    );
    expect(container.querySelector("button")!.dataset.dragging).toBe("true");
    await act(async () => releaseMove());
    expect(errors).toEqual([]);
    expect(container.querySelector("button")!.dataset.dragging).toBe("true");
    expect(synchronized).toEqual([]);
  } finally {
    logged.mockRestore();
  }
});

test("WSL batch preflight keeps case-distinct parents, source names and existing names", async () => {
  // Exercise provider path semantics independently of the product's WSL capability rollout.
  const capability = spyOn(capabilities, "isBackendCapabilityAvailable").mockReturnValue(true);
  try {
    const rootPath = "wsl://Ubuntu/project";
    const entries = ["a.ts", "A.ts"].map((name) => ({
      path: `${rootPath}/Src/${name}`,
      name,
      isDir: false,
    }));
    mockIPC((command, args) => {
      if (command === "wsl_read_directory") return [{ name: "a.TS", is_dir: false }];
      if (command === "wsl_rename_path") {
        const payload = args as { sourcePath: string; targetPath: string };
        nativeMoves.push([payload.sourcePath, payload.targetPath]);
        return;
      }
      throw new Error(`Unexpected native call: ${command}`);
    });
    await dropFiles(rootPath, entries, `${rootPath}/src`);
    expect(nativeMoves).toEqual([
      ["/project/Src/a.ts", "/project/src/a.ts"],
      ["/project/Src/A.ts", "/project/src/A.ts"],
    ]);
    expect(synchronized).toEqual(
      entries.map((entry) => [entry.path, `${rootPath}/src/${entry.name}`]),
    );
    expect(errors).toEqual([]);
  } finally {
    capability.mockRestore();
  }
});

test("Windows preflight still rejects an existing destination with different casing", async () => {
  mockIPC((command) => {
    if (command === "plugin:fs|read_dir")
      return [{ name: "A.TS", isDirectory: false, isSymlink: false }];
    throw new Error(`Unexpected native call: ${command}`);
  });
  await dropFiles(workspace, files.slice(0, 1));
  expect(nativeMoves).toEqual([]);
  expect(synchronized).toEqual([]);
  expect(errors).toEqual(["Destination already contains a.ts"]);
});
