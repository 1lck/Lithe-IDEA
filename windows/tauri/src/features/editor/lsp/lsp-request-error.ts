export interface NormalizedLspError {
  message: string;
  code?: string;
  details?: string;
}

/** Preserves stable Core error fields when the adapter throws an Error object. */
export function normalizeLspError(error: unknown): NormalizedLspError {
  if (error instanceof Error) {
    const coded = error as Error & { code?: unknown; details?: unknown };
    return {
      message: error.message,
      code: typeof coded.code === "string" ? coded.code : undefined,
      details: typeof coded.details === "string" ? coded.details : undefined,
    };
  }

  if (typeof error === "string") return { message: error };

  if (error && typeof error === "object") {
    const candidate = error as { message?: unknown; code?: unknown; details?: unknown };
    if (typeof candidate.message === "string" && candidate.message.trim().length > 0) {
      return {
        message: candidate.message,
        code: typeof candidate.code === "string" ? candidate.code : undefined,
        details: typeof candidate.details === "string" ? candidate.details : undefined,
      };
    }
    try {
      return { message: JSON.stringify(error) };
    } catch {
      return { message: String(error) };
    }
  }

  return { message: String(error) };
}

export function isCanceledLspRequest(error: unknown): boolean {
  const normalized = normalizeLspError(error);
  const message = normalized.message.toLowerCase();
  return (
    normalized.code === "cancelled" ||
    message === "canceled" ||
    message.includes("canceled: canceled") ||
    message.includes("request canceled") ||
    message.includes("request cancelled") ||
    message.includes("document changed before") ||
    message.includes("content modified") ||
    message.includes("-32801")
  );
}

/**
 * JDTLS registers CodeLens after the initialize response. Only that precise
 * capability gap and ordinary request cancellation are safe startup retries.
 */
export function isTransientJavaMarkerError(error: unknown): boolean {
  if (isCanceledLspRequest(error)) return true;
  const normalized = normalizeLspError(error);
  return normalized.code === "not_supported" && normalized.details === "codeLens";
}
