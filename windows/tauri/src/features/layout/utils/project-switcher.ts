export function shouldShowProjectSwitcher(
  showProjectSwitcher: boolean,
  openFoldersInNewWindow: boolean,
) {
  return showProjectSwitcher && !openFoldersInNewWindow;
}
