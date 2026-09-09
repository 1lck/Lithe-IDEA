export interface UpdateControlVisibility {
  showTitleBarControl: boolean;
  showWelcomeControl: boolean;
}

export function getUpdateControlVisibility(
  rootFolderPath: string | null | undefined,
): UpdateControlVisibility {
  const hasOpenProject = Boolean(rootFolderPath);

  return {
    showTitleBarControl: hasOpenProject,
    showWelcomeControl: !hasOpenProject,
  };
}
