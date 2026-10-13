import { expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { createPaneContent } from "@/features/editor/stores/buffer-content-factory";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { useRecentFilesStore } from "@/features/file-system/stores/recent-files.store";
import { installHappyDom } from "@/test-utils/happy-dom";
import type { CategorizedFiles } from "../types/quick-open.types";
import { useFileSearch } from "./use-file-search";

const target = {
  name: "independent-commit-diff.ts",
  path: "D:/fixture/project/src/independent-commit-diff.ts",
  isDir: false,
};
const other = { name: "other.ts", path: "D:/fixture/project/src/other.ts", isDir: false };

for (const backend of [false, true]) {
  test(`filename search includes the active editor; empty switcher excludes it (backend=${backend})`, async () => {
    const restoreDom = installHappyDom();
    const environment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
    const previousAct = environment.IS_REACT_ACT_ENVIRONMENT;
    const previousBuffers = useBufferStore.getState();
    const previousRecent = useRecentFilesStore.getState().recentFiles;
    const host = document.createElement("div");
    let root: Root | undefined;
    let results: CategorizedFiles | undefined;
    function Probe({ query }: { query: string }) {
      results = useFileSearch(
        [target, other],
        query,
        backend ? [{ ...target, relative_path: target.name, score: 1000 }] : null,
        {
          useBackendResults: backend,
          hasLoadedFiles: true,
          rootFolderPath: "D:/fixture/project",
        },
      );
      return null;
    }
    try {
      environment.IS_REACT_ACT_ENVIRONMENT = true;
      useBufferStore.setState({
        buffers: [createPaneContent("active", { type: "editor", ...target, content: "" })],
        activeBufferId: "active",
      });
      useRecentFilesStore.setState({ recentFiles: [] });
      document.body.append(host);
      root = createRoot(host);
      const mountedRoot = root;
      await act(async () => mountedRoot.render(<Probe query="independent-commit-diff" />));
      expect(results?.openBufferFiles.map((file) => file.path)).toEqual([target.path]);
      await act(async () => mountedRoot.render(<Probe query="" />));
      expect(results?.openBufferFiles).toEqual([]);
      expect(results?.otherFiles.map((file) => file.path)).toEqual([other.path]);
      if (!backend) {
        await act(async () => mountedRoot.render(<Probe query="independentcommitdiff" />));
        expect(results?.openBufferFiles.map((file) => file.path)).toEqual([target.path]);
      }
    } finally {
      try {
        await act(async () => root?.unmount());
      } finally {
        host.remove();
        useBufferStore.setState(previousBuffers);
        useRecentFilesStore.setState({ recentFiles: previousRecent });
        if (previousAct === undefined) delete environment.IS_REACT_ACT_ENVIRONMENT;
        else environment.IS_REACT_ACT_ENVIRONMENT = previousAct;
        restoreDom();
      }
    }
  });
}

test("typed queries find switcher-ignored files while the empty switcher hides them", async () => {
  const restoreDom = installHappyDom();
  const environment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
  const previousAct = environment.IS_REACT_ACT_ENVIRONMENT;
  const previousBuffers = useBufferStore.getState();
  const previousRecent = useRecentFilesStore.getState().recentFiles;
  const host = document.createElement("div");
  let root: Root | undefined;
  let results: CategorizedFiles | undefined;
  const gitignore = { name: ".gitignore", path: "D:/fixture/project/.gitignore", isDir: false };
  const cargoLock = { name: "Cargo.lock", path: "D:/fixture/project/Cargo.lock", isDir: false };
  function Probe({ query }: { query: string }) {
    results = useFileSearch([target, gitignore, cargoLock], query, null, {
      hasLoadedFiles: true,
      rootFolderPath: "D:/fixture/project",
    });
    return null;
  }
  try {
    environment.IS_REACT_ACT_ENVIRONMENT = true;
    // Neither file is the active editor, so only the full snapshot can supply them.
    useBufferStore.setState({
      buffers: [createPaneContent("active", { type: "editor", ...target, content: "" })],
      activeBufferId: "active",
    });
    useRecentFilesStore.setState({ recentFiles: [] });
    document.body.append(host);
    root = createRoot(host);
    const mountedRoot = root;
    await act(async () => mountedRoot.render(<Probe query=".gitignore" />));
    expect(results?.otherFiles.map((file) => file.path)).toContain(gitignore.path);
    await act(async () => mountedRoot.render(<Probe query="Cargo.lock" />));
    expect(results?.otherFiles.map((file) => file.path)).toContain(cargoLock.path);
    await act(async () => mountedRoot.render(<Probe query="" />));
    expect(results?.otherFiles).toEqual([]);
    expect(results?.recentFilesInResults).toEqual([]);
  } finally {
    try {
      await act(async () => root?.unmount());
    } finally {
      host.remove();
      useBufferStore.setState(previousBuffers);
      useRecentFilesStore.setState({ recentFiles: previousRecent });
      if (previousAct === undefined) delete environment.IS_REACT_ACT_ENVIRONMENT;
      else environment.IS_REACT_ACT_ENVIRONMENT = previousAct;
      restoreDom();
    }
  }
});
