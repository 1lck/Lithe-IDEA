import type { LspStatus } from "./stores/lsp.store";

export function languageDisplayName(languageId: string | undefined): string {
  if (!languageId) return "Language";
  if (languageId === "java") return "Java";
  return languageId;
}

export function languageServerUnavailableMessage(args: {
  languageId?: string;
  status: LspStatus;
  lastError?: string;
  hasSession: boolean;
  ready?: boolean;
  featuresKnown?: boolean;
  supportsFeature?: boolean;
  featureLabel?: string;
}): string | null {
  if (args.hasSession && args.ready !== false && args.supportsFeature !== false) return null;

  const name = languageDisplayName(args.languageId);
  if (args.hasSession && args.ready && args.featuresKnown && args.supportsFeature === false) {
    return `${name} language server does not support ${args.featureLabel || "this feature"}.`;
  }
  if (args.status === "connecting") {
    return `${name} language server is starting.`;
  }
  if (args.status === "error") {
    return args.lastError?.trim() || `${name} language server failed.`;
  }
  return args.lastError?.trim() || `${name} language server is not ready.`;
}
