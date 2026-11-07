/** Startup owns this indicator even when the workspace was already initialized. */
export async function restoreStartupWorkspace(
  workspaceId: string,
  switchToProject: (workspaceId: string) => Promise<boolean>,
  setIsSwitchingProject: (value: boolean) => void,
) {
  setIsSwitchingProject(true);
  try {
    return await switchToProject(workspaceId);
  } finally {
    // Keep the captured setter: activation can change the currently scoped store.
    setIsSwitchingProject(false);
  }
}
