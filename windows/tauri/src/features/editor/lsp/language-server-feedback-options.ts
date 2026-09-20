export function languageServerFeedbackId(workspacePath: string, languageId: string): string {
  return `${workspacePath.replace(/\\/g, "/").toLowerCase()}:${languageId}`;
}

export function languageServerPreparingToastOptions(workspacePath: string, languageId: string) {
  return {
    id: languageServerFeedbackId(workspacePath, languageId),
    duration: Number.POSITIVE_INFINITY,
    className: "pointer-events-none",
    closeButton: false,
  } as const;
}

export function languageServerInteractiveToastOptions(workspacePath: string, languageId: string) {
  return {
    id: languageServerFeedbackId(workspacePath, languageId),
    className: "",
    closeButton: true,
  } as const;
}
