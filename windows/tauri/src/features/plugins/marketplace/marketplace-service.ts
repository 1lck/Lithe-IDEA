/**
 * Frontend helpers around the injected marketplace service port. The real
 * backend binding lives in `../declarative-marketplace`; nothing here adds a
 * second IPC group or fabricates a connected backend.
 */

/** Host operation IDs: ASCII letters, digits, `-` and `_`, at most 128 bytes. */
const OPERATION_ID_ALPHABET = "abcdefghijklmnopqrstuvwxyz0123456789";

export interface MarketplaceOperationIds {
  /** Returns a fresh ID the host registry accepts for this window. */
  next(): string;
}

/**
 * Creates page-scoped operation IDs. Randomness keeps two pages of one window
 * from colliding after a remount; the counter keeps IDs unique within a page
 * even with a degenerate random source.
 */
export function createMarketplaceOperationIds(
  random: () => number = Math.random,
): MarketplaceOperationIds {
  let counter = 0;
  return {
    next(): string {
      counter += 1;
      let suffix = "";
      for (let position = 0; position < 8; position += 1) {
        suffix += OPERATION_ID_ALPHABET[Math.floor(random() * OPERATION_ID_ALPHABET.length)];
      }
      return `mkt-${counter}-${suffix}`;
    },
  };
}

/** Translation keys for host rejections the page can name precisely. */
export type MarketplaceErrorKey =
  | "cancelled"
  | "sourceUnavailable"
  | "indexChanged"
  | "approvalRequired"
  | "digestMismatch"
  | "tooManyOperations"
  | "generic";

/** Maps a raw host rejection to a stable translation key. The host commands
 * reject with plain strings, so known fragments are matched conservatively;
 * anything unrecognized keeps its raw message for diagnosis. */
export function describeMarketplaceError(reason: unknown): {
  key: MarketplaceErrorKey;
  message: string;
} {
  const message =
    typeof reason === "object" && reason !== null && "message" in reason
      ? String((reason as { message: unknown }).message)
      : String(reason);
  if (message.includes("marketplace operation cancelled")) {
    return { key: "cancelled", message };
  }
  if (message.includes("the marketplace source was removed or disabled")) {
    return { key: "sourceUnavailable", message };
  }
  if (
    message.includes("the source index changed") ||
    message.includes("the selected index expired")
  ) {
    return { key: "indexChanged", message };
  }
  if (message.includes("explicit approval is required")) {
    return { key: "approvalRequired", message };
  }
  if (message.includes("the review digest does not match")) {
    return { key: "digestMismatch", message };
  }
  if (message.includes("too many pending operations")) {
    return { key: "tooManyOperations", message };
  }
  return { key: "generic", message };
}

/** A user-initiated cancellation is an answer, not a failure to surface. */
export function isMarketplaceCancellation(reason: unknown): boolean {
  return describeMarketplaceError(reason).key === "cancelled";
}
