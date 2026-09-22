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
