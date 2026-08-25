import type { LspDocumentAvailability } from "./lsp-client";
import type { LspStatus } from "./stores/lsp.store";

export type LanguageServerNavigationBlock =
  | { reason: "preparing"; languageId?: string }
  | { reason: "failed"; languageId?: string }
  | { reason: "unsupported"; languageId?: string }
  | { reason: "notReady"; languageId?: string };

/** Projects runtime state to a stable UI reason without creating presentation text. */
export function languageServerNavigationBlock(args: {
  availability: LspDocumentAvailability;
  fallbackStatus: LspStatus;
}): LanguageServerNavigationBlock | null {
  const { availability } = args;
  if (availability.phase === "ready") {
    if (availability.feature === "supported") return null;
    if (availability.feature === "unknown") {
      return { reason: "preparing", languageId: availability.languageId };
    }
    return { reason: "unsupported", languageId: availability.languageId };
  }
  if (availability.phase === "preparing" || args.fallbackStatus === "connecting") {
    return { reason: "preparing", languageId: availability.languageId };
  }
  if (availability.phase === "failed" || args.fallbackStatus === "error") {
    return { reason: "failed", languageId: availability.languageId };
  }
  return { reason: "notReady", languageId: availability.languageId };
}
