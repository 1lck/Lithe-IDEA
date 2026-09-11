import { getRelativePath } from "@/utils/path-helpers";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { useActiveWorkspaceId } from "@/features/workspace/stores/create-workspace-scoped-store";
import { scanMavenProject } from "../api/maven-core-api";
import {
  loadMavenProjectForWorkspace,
  useMavenStore,
} from "../stores/maven.store";
import { ensureMavenProcessListeners } from "../hooks/use-maven-process-events";

export async function canRunMavenTest(root: string, filePath: string): Promise<boolean> {
  const relativePath = getRelativePath(filePath, root);
  if (!relativePath || relativePath === filePath) return false;
  try {
    return (await scanMavenProject(root, [relativePath])) !== null;
  } catch {
    return false;
  }
}

export async function runMavenTestAction(
  filePath: string,
  method?: string,
  workspaceId = useActiveWorkspaceId(),
): Promise<void> {
  const root = useFileSystemStore.getStore(workspaceId).getState().rootFolderPath;
  if (!root) throw new Error("Open a workspace before running a Maven test.");

  await ensureMavenProcessListeners();
  await loadMavenProjectForWorkspace(root, [getRelativePath(filePath, root)], workspaceId);
  const store = useMavenStore.getStore(workspaceId);
  if (method) {
    await store.getState().actions.runTestMethod(filePath, method);
  } else {
    await store.getState().actions.runTestClass(filePath);
  }
}
