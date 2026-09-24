import type { UsagePlatformId } from "../types/usage.types";

/**
 * Cost estimation.
 *
 * A local session log carries no billed amount, so only model ids verified by
 * hand are priced here. All prices are the standard, non-batch, US dollar price
 * per million text tokens.
 *
 * An unknown model, a variant that is not a date snapshot, and a Claude request
 * whose cache write TTL cannot be known all return null and show as a dash:
 * showing nothing beats inventing a number.
 *
 * Verified 2026-09-16:
 * - OpenAI    https://developers.openai.com/api/docs/models/compare
 * - Anthropic https://platform.claude.com/docs/en/about-claude/pricing
 */
export interface ModelPrice {
  platform: UsagePlatformId;
  model: string;
  input: number;
  cachedInput: number;
  output: number;
  /** null when the local log cannot say which of the TTL prices applies */
  cacheWrite: number | null;
}

export const MODEL_PRICES: readonly ModelPrice[] = [
  // Anthropic Claude API, standard global. A cache write has one price for a
  // 5 minute TTL and another for an hour, and the local log records neither.
  {
    platform: "claude",
    model: "claude-opus-4-8",
    input: 5,
    cachedInput: 0.5,
    output: 25,
    cacheWrite: null,
  },
  {
    platform: "claude",
    model: "claude-opus-4-7",
    input: 5,
    cachedInput: 0.5,
    output: 25,
    cacheWrite: null,
  },
  {
    platform: "claude",
    model: "claude-opus-4-6",
    input: 5,
    cachedInput: 0.5,
    output: 25,
    cacheWrite: null,
  },
  {
    platform: "claude",
    model: "claude-opus-4-5",
    input: 5,
    cachedInput: 0.5,
    output: 25,
    cacheWrite: null,
  },
  {
    platform: "claude",
    model: "claude-sonnet-4-6",
    input: 3,
    cachedInput: 0.3,
    output: 15,
    cacheWrite: null,
  },
  {
    platform: "claude",
    model: "claude-sonnet-4-5",
    input: 3,
    cachedInput: 0.3,
    output: 15,
    cacheWrite: null,
  },
  {
    platform: "claude",
    model: "claude-sonnet-4",
    input: 3,
    cachedInput: 0.3,
    output: 15,
    cacheWrite: null,
  },
  {
    platform: "claude",
    model: "claude-haiku-4-5",
    input: 1,
    cachedInput: 0.1,
    output: 5,
    cacheWrite: null,
  },
  {
    platform: "claude",
    model: "claude-opus-4-1",
    input: 15,
    cachedInput: 1.5,
    output: 75,
    cacheWrite: null,
  },
  {
    platform: "claude",
    model: "claude-opus-4",
    input: 15,
    cachedInput: 1.5,
    output: 75,
    cacheWrite: null,
  },
  {
    platform: "claude",
    model: "claude-3-7-sonnet",
    input: 3,
    cachedInput: 0.3,
    output: 15,
    cacheWrite: null,
  },
  {
    platform: "claude",
    model: "claude-3-5-sonnet",
    input: 3,
    cachedInput: 0.3,
    output: 15,
    cacheWrite: null,
  },
  {
    platform: "claude",
    model: "claude-3-5-haiku",
    input: 0.8,
    cachedInput: 0.08,
    output: 4,
    cacheWrite: null,
  },
  // OpenAI API. The cached input price is taken from the published table rather
  // than derived from one multiplier.
  {
    platform: "codex",
    model: "gpt-6-astra",
    input: 10,
    cachedInput: 1,
    output: 50,
    cacheWrite: 12.5,
  },
  {
    platform: "codex",
    model: "gpt-5.6-sol",
    input: 4,
    cachedInput: 0.4,
    output: 20,
    cacheWrite: null,
  },
  { platform: "codex", model: "gpt-5.6", input: 4, cachedInput: 0.4, output: 20, cacheWrite: null },
  {
    platform: "codex",
    model: "gpt-5.6-terra",
    input: 2,
    cachedInput: 0.2,
    output: 12,
    cacheWrite: null,
  },
  {
    platform: "codex",
    model: "gpt-5.6-luna",
    input: 0.2,
    cachedInput: 0.02,
    output: 1.2,
    cacheWrite: null,
  },
  {
    platform: "codex",
    model: "gpt-5.3-codex",
    input: 1.75,
    cachedInput: 0.175,
    output: 14,
    cacheWrite: null,
  },
  {
    platform: "codex",
    model: "gpt-5.2-codex",
    input: 1.75,
    cachedInput: 0.175,
    output: 14,
    cacheWrite: null,
  },
  {
    platform: "codex",
    model: "gpt-5.2",
    input: 1.75,
    cachedInput: 0.175,
    output: 14,
    cacheWrite: null,
  },
  {
    platform: "codex",
    model: "gpt-5.1-codex-max",
    input: 1.25,
    cachedInput: 0.125,
    output: 10,
    cacheWrite: null,
  },
  {
    platform: "codex",
    model: "gpt-5.1-codex",
    input: 1.25,
    cachedInput: 0.125,
    output: 10,
    cacheWrite: null,
  },
  {
    platform: "codex",
    model: "gpt-5.1",
    input: 1.25,
    cachedInput: 0.125,
    output: 10,
    cacheWrite: null,
  },
  {
    platform: "codex",
    model: "gpt-5-codex",
    input: 1.25,
    cachedInput: 0.125,
    output: 10,
    cacheWrite: null,
  },
  {
    platform: "codex",
    model: "gpt-5",
    input: 1.25,
    cachedInput: 0.125,
    output: 10,
    cacheWrite: null,
  },
  {
    platform: "codex",
    model: "codex-mini-latest",
    input: 1.5,
    cachedInput: 0.375,
    output: 6,
    cacheWrite: null,
  },
  { platform: "codex", model: "gpt-4.1", input: 2, cachedInput: 0.5, output: 8, cacheWrite: null },
  {
    platform: "codex",
    model: "gpt-4.1-mini",
    input: 0.4,
    cachedInput: 0.1,
    output: 1.6,
    cacheWrite: null,
  },
  {
    platform: "codex",
    model: "gpt-4.1-nano",
    input: 0.1,
    cachedInput: 0.025,
    output: 0.4,
    cacheWrite: null,
  },
  {
    platform: "codex",
    model: "gpt-4o",
    input: 2.5,
    cachedInput: 1.25,
    output: 10,
    cacheWrite: null,
  },
  {
    platform: "codex",
    model: "gpt-4o-mini",
    input: 0.15,
    cachedInput: 0.075,
    output: 0.6,
    cacheWrite: null,
  },
];

/** A date snapshot suffix of the shape `-YYYY-MM-DD` */
function isDateSnapshotSuffix(value: string): boolean {
  if (value.length !== 11 || value[0] !== "-") return false;
  for (let index = 1; index < 11; index += 1) {
    const char = value[index];
    if (index === 5 || index === 8) {
      if (char !== "-") return false;
      continue;
    }
    if (char < "0" || char > "9") return false;
  }
  return true;
}

/**
 * Matches a model id exactly, or the same model carrying a date snapshot
 * suffix. `gpt-4.1-2025-04-14` matches; `gpt-5.2-codex-preview` and `gpt-5.20`
 * do not, because both are different models rather than variants of one.
 */
export function priceOf(platform: UsagePlatformId | null, model: string): ModelPrice | null {
  const candidate = model.toLowerCase();
  for (const price of MODEL_PRICES) {
    if (platform !== null && price.platform !== platform) continue;
    if (candidate === price.model) return price;
    if (
      candidate.startsWith(price.model) &&
      isDateSnapshotSuffix(candidate.slice(price.model.length))
    ) {
      return price;
    }
  }
  return null;
}

/**
 * Estimated cost of one request, in US dollars. Null when the model or a
 * billing category cannot be matched exactly.
 *
 * The two sources define `input_tokens` differently, so one formula cannot
 * serve both:
 * - Claude excludes the cache from `input_tokens`, so the ordinary input is
 *   that value as it stands
 * - Codex includes the cache in `input_tokens`, so it has to come off first,
 *   otherwise the cache is billed twice
 */
export function estimateCost(
  platform: UsagePlatformId,
  model: string | null,
  input: number,
  output: number,
  cacheWrite: number,
  cacheRead: number,
): number | null {
  if (model === null) return null;
  const price = priceOf(platform, model);
  if (!price) return null;

  const writePrice = cacheWrite === 0 ? 0 : price.cacheWrite;
  if (writePrice === null) return null;

  const ordinaryInput =
    price.platform === "codex" ? Math.max(0, input - cacheRead - cacheWrite) : input;

  return (
    (ordinaryInput * price.input +
      output * price.output +
      cacheWrite * writePrice +
      cacheRead * price.cachedInput) /
    1_000_000
  );
}
