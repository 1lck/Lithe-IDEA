export function createDefaultTerminalHandler(
  createTerminalWithProfile: (profileId?: string) => void,
): () => void {
  return () => createTerminalWithProfile();
}

/** Folder actions share the bottom-panel entry used by menus and shortcuts. */
export function requestNewTerminal(workingDirectory: string): void {
  window.dispatchEvent(new window.CustomEvent("terminal-new", { detail: { workingDirectory } }));
}

export function createNewTerminalEventHandler(
  createTerminal: (workingDirectory?: string) => void,
): (event: Event) => void {
  return (event) => {
    const directory = (event as CustomEvent<{ workingDirectory?: unknown }>).detail
      ?.workingDirectory;
    createTerminal(typeof directory === "string" && directory.trim() ? directory : undefined);
  };
}
