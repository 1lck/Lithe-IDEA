export function createDefaultTerminalHandler(
  createTerminalWithProfile: (profileId?: string) => void,
): () => void {
  return () => createTerminalWithProfile();
}
