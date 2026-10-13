import { expect, spyOn, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import * as api from "@/features/file-search/lib/file-search-api";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { installHappyDom } from "@/test-utils/happy-dom";
import { useFileLoader } from "./use-file-loader";

test("loads one snapshot per opening, refreshes created files and rejects late workspace results", async () => {
  const restoreDom = installHappyDom();
  const environment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
  const previousAct = environment.IS_REACT_ACT_ENVIRONMENT;
  const previousStore = useFileSystemStore.getState();
  const host = document.createElement("div");
  let root: Root | undefined;
  let result: ReturnType<typeof useFileLoader> | undefined;
  let releaseOld: ((files: api.FffIndexedFile[]) => void) | undefined;
  const oldRequest = new Promise<api.FffIndexedFile[]>((resolve) => {
    releaseOld = resolve;
  });
  const file = (name: string) => ({
    name,
    path: `D:/fixture/project/${name}`,
    relative_path: name,
  });
  const list = spyOn(api, "fffListFiles")
    .mockResolvedValueOnce([file("before.ts"), file(".gitignore")])
    .mockResolvedValueOnce([file("after.ts")])
    .mockImplementationOnce(() => oldRequest)
    .mockResolvedValueOnce([file("new-workspace.ts")]);
  const status = spyOn(api, "fffScanStatus");
  function Probe({ visible }: { visible: boolean }) {
    result = useFileLoader(visible);
    return null;
  }
  try {
    environment.IS_REACT_ACT_ENVIRONMENT = true;
    useFileSystemStore.setState({ rootFolderPath: "D:/fixture/project", workspaceFolders: [] });
    document.body.append(host);
    root = createRoot(host);
    const mountedRoot = root;
    await act(async () => mountedRoot.render(<Probe visible />));
    // The snapshot is unfiltered so explicit filename searches can reach ignored-by-switcher files.
    expect(result?.files.map((file) => file.name)).toEqual(["before.ts", ".gitignore"]);
    await act(async () => mountedRoot.render(<Probe visible />));
    expect(list).toHaveBeenCalledTimes(1);
    expect(status).not.toHaveBeenCalled();
    await act(async () => mountedRoot.render(<Probe visible={false} />));
    await act(async () => mountedRoot.render(<Probe visible />));
    expect(result?.files.map((file) => file.name)).toEqual(["after.ts"]);
    await act(async () => mountedRoot.render(<Probe visible={false} />));
    await act(async () => mountedRoot.render(<Probe visible />));
    await act(async () => useFileSystemStore.setState({ rootFolderPath: "D:/fixture/another" }));
    await act(async () => {
      releaseOld?.([file("stale.ts")]);
      await oldRequest;
    });
    expect(result?.files.map((file) => file.name)).toEqual(["new-workspace.ts"]);
    expect(result?.isLoadingFiles).toBe(false);
  } finally {
    try {
      await act(async () => {
        releaseOld?.([]);
        await oldRequest;
        root?.unmount();
      });
    } finally {
      host.remove();
      list.mockRestore();
      status.mockRestore();
      useFileSystemStore.setState(previousStore);
      if (previousAct === undefined) delete environment.IS_REACT_ACT_ENVIRONMENT;
      else environment.IS_REACT_ACT_ENVIRONMENT = previousAct;
      restoreDom();
    }
  }
});
