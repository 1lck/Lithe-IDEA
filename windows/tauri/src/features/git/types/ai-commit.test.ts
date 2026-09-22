import { expect, test } from "bun:test";
import { DEFAULT_COMMIT_AI, newCommitProvider, normalizeCommitAI } from "./ai-commit";

test("normalizes malformed preferences and strips secrets from profiles", () => {
  const result = normalizeCommitAI({
    providers: [
      { ...newCommitProvider("example"), apiKey: "must-not-persist" },
      { id: "../invalid" },
    ],
    activeProviderId: "missing",
    maximumDiffCharacters: Number.NaN,
    subjectMaximumLength: 9999,
    format: "invalid",
    customInstructions: 42,
  });
  expect(result.providers).toHaveLength(1);
  expect(result.activeProviderId).toBe("example");
  expect(JSON.stringify(result)).not.toContain("must-not-persist");
  expect(result.maximumDiffCharacters).toBe(32000);
  expect(result.subjectMaximumLength).toBe(200);
  expect(result.format).toBe("conventional");
  expect(result.customInstructions).toBe("");
});

test("preserves explicit gateway compatibility and reasoning preferences", () => {
  const provider = newCommitProvider("example");
  expect(provider.chatTokenLimitField).toBe("max_completion_tokens");
  expect(normalizeCommitAI(undefined).reasoningEffort).toBe("default");
  const settings = normalizeCommitAI({
    providers: [{ ...provider, chatTokenLimitField: "max_tokens" }],
    reasoningEffort: "none",
  });
  expect(settings.providers[0].chatTokenLimitField).toBe("max_tokens");
  expect(settings.reasoningEffort).toBe("none");
  const legacy = { ...provider } as Partial<typeof provider>;
  delete legacy.chatTokenLimitField;
  expect(normalizeCommitAI({ providers: [legacy] }).providers[0].chatTokenLimitField).toBe(
    "max_completion_tokens",
  );
});
test("old settings receive independent defaults without changing chat preferences", () => {
  expect(normalizeCommitAI(undefined)).toEqual(DEFAULT_COMMIT_AI);
  const value = normalizeCommitAI({
    ...DEFAULT_COMMIT_AI,
    enabled: false,
    language: "simplifiedChinese",
    format: "custom",
    customInstructions: "Use ticket IDs",
  });
  expect(value.enabled).toBe(false);
  expect(value.customInstructions).toBe("Use ticket IDs");
});
