/** Brief throttle after a language-server startup failure before automatic retries. */
export const LANGUAGE_SERVER_FAILURE_COOLDOWN_MS = 5_000;

/**
 * Returns whether startup should stay blocked for this server key.
 * Expired cooldown entries are removed so later automatic starts can retry.
 */
export function isLanguageServerFailureCoolingDown(
  failures: Map<string, number>,
  serverKey: string,
  nowMs: number,
  cooldownMs: number = LANGUAGE_SERVER_FAILURE_COOLDOWN_MS,
): boolean {
  const failedAtMs = failures.get(serverKey);
  if (failedAtMs === undefined) {
    return false;
  }

  if (nowMs - failedAtMs >= cooldownMs) {
    failures.delete(serverKey);
    return false;
  }

  return true;
}

export function recordLanguageServerFailure(
  failures: Map<string, number>,
  serverKey: string,
  failedAtMs: number,
): void {
  failures.set(serverKey, failedAtMs);
}

export function clearLanguageServerFailure(failures: Map<string, number>, serverKey: string): void {
  failures.delete(serverKey);
}
