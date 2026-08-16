import { describe, expect, test } from "bun:test";
import type { GitHistorySnapshot } from "@/features/git/types/git.types";
import { adaptCoreResult } from "./core-result-adapter";

describe("git history result adaptation", () => {
  test("preserves commits and the shared core pagination state", () => {
    const result = adaptCoreResult<GitHistorySnapshot>(
      "git_log",
      { repoPath: "C:/work", limit: 50 },
      {
        commits: [
          {
            hash: "abc123",
            subject: "First commit",
            authorName: "Developer",
            authorEmail: "developer@example.invalid",
            date: "2026/08/16 10:00",
          },
        ],
        hasMore: true,
      },
    );

    expect(result).toEqual({
      commits: [
        {
          hash: "abc123",
          message: "First commit",
          author: "Developer",
          email: "developer@example.invalid",
          date: "2026/08/16 10:00",
        },
      ],
      hasMore: true,
    });
  });

  test("defaults missing history fields to an exhausted empty snapshot", () => {
    expect(adaptCoreResult<GitHistorySnapshot>("git_log", undefined, {})).toEqual({
      commits: [],
      hasMore: false,
    });
  });
});
