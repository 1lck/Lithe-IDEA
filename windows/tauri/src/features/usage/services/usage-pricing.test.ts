import { describe, expect, test } from "bun:test";
import { estimateCost, priceOf } from "./usage-pricing";

describe("model price lookup", () => {
  test("matches exact ids and date snapshots, but not other variants", () => {
    expect(priceOf("codex", "gpt-5.2-codex")).not.toBeNull();
    expect(priceOf("codex", "gpt-4.1-2025-04-14")).not.toBeNull();
    // The suffix has to be a whole date. `preview` and `gpt-5.20` are other
    // models, not variants of this one.
    expect(priceOf("codex", "gpt-5.2-codex-preview")).toBeNull();
    expect(priceOf("codex", "gpt-5.20")).toBeNull();
    expect(priceOf("claude", "claude-opus-4-9")).toBeNull();
  });

  test("is case insensitive", () => {
    expect(priceOf("claude", "Claude-Sonnet-4-5")).not.toBeNull();
  });

  test("does not cross platforms", () => {
    expect(priceOf("claude", "gpt-5")).toBeNull();
    expect(priceOf("codex", "claude-sonnet-4-5")).toBeNull();
  });
});

describe("cost estimation", () => {
  test("codex input that already includes cache is not charged twice", () => {
    // Codex already counts the cache inside `input_tokens`, so the ordinary
    // input comes off first and the cache is not billed twice.
    const value = estimateCost("codex", "gpt-5", 1_000, 500, 0, 800);
    const expected = (200 * 1.25 + 800 * 0.125 + 500 * 10) / 1_000_000;
    expect(value).not.toBeNull();
    expect(Math.abs((value ?? 0) - expected)).toBeLessThan(1e-12);
  });

  test("claude input excludes cache, so it is charged as given", () => {
    const value = estimateCost("claude", "claude-sonnet-4-5", 1_000, 500, 0, 800);
    const expected = (1_000 * 3 + 500 * 15 + 800 * 0.3) / 1_000_000;
    expect(value).not.toBeNull();
    expect(Math.abs((value ?? 0) - expected)).toBeLessThan(1e-12);
  });

  test("claude cache write without a known ttl is not guessed", () => {
    // The local log has no cache TTL, and 5m and 1h are priced differently, so
    // nothing is reported rather than a guess.
    expect(estimateCost("claude", "claude-sonnet-4-5", 1_000, 500, 100, 800)).toBeNull();
    expect(estimateCost("claude", "claude-sonnet-4-5", 1_000, 500, 0, 800)).not.toBeNull();
  });

  test("codex knows its cache write price, so it can still report", () => {
    const value = estimateCost("codex", "gpt-6-astra", 1_000, 500, 100, 800);
    expect(value).not.toBeNull();
  });

  test("unknown or missing model is not priced", () => {
    expect(estimateCost("claude", null, 1, 1, 0, 0)).toBeNull();
    expect(estimateCost("claude", "some-future-model", 1, 1, 0, 0)).toBeNull();
  });
});
