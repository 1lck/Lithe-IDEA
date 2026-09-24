import { expect, test } from "bun:test";
import { fetchPlatformQuota } from "./quota-client";
import type { PlatformQuota } from "../types/quota.types";

function snapshot(overrides: Partial<PlatformQuota>): PlatformQuota {
  return {
    platform: "claude",
    connection: "auth",
    windows: [],
    failure: null,
    detail: null,
    scannedPaths: [],
    plan: null,
    fetchedAt: null,
    ...overrides,
  };
}

test("the quota probe is a host command, not a web-layer request", async () => {
  const calls: Array<{ command: string; args: Record<string, unknown> | undefined }> = [];
  const stub = async <T>(command: string, args?: Record<string, unknown>): Promise<T> => {
    calls.push({ command, args });
    return snapshot({ platform: "codex" }) as T;
  };

  const result = await fetchPlatformQuota("codex", stub);

  // The credential and the HTTP request live behind this command; if the token
  // ever had to travel as an argument, this assertion would be the place that
  // notices.
  expect(calls).toEqual([{ command: "usage_quota", args: { platform: "codex" } }]);
  expect(result.platform).toBe("codex");
});

test("a host failure category reaches the caller unchanged", async () => {
  const failure = snapshot({
    platform: "codex",
    connection: "relay",
    failure: "unsupported",
    scannedPaths: ["/home/.codex/auth.json"],
  });
  const stub = async <T>(): Promise<T> => failure as T;

  const result = await fetchPlatformQuota("codex", stub);

  expect(result.failure).toBe("unsupported");
  expect(result.connection).toBe("relay");
  expect(result.windows).toEqual([]);
});
