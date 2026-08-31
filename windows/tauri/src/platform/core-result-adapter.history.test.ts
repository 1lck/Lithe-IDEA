import { describe, expect, test } from "bun:test";
import type { GitHistorySnapshot } from "@/features/git/types/git.types";
import { adaptCoreResult } from "./core-result-adapter";

describe("git history result adaptation", () => {
  test("preserves commits and the shared core pagination state", () => {
    const result = adaptCoreResult<GitHistorySnapshot>(
      "git_log",
      { repoPath: "C:/work", limit: 50 },
      {
        references: [
          {
            fullName: "refs/heads/main",
            shortName: "main",
            kind: "local",
            isCurrent: true,
            upstreamShortName: "origin/main",
          },
        ],
        recentReferences: [
          {
            fullName: "refs/heads/main",
            shortName: "main",
            kind: "local",
            isCurrent: true,
            upstreamShortName: "origin/main",
          },
        ],
        commits: [
          {
            hash: "abc123",
            shortHash: "abc123",
            parentHashes: ["parent123"],
            subject: "First commit",
            authorName: "Developer",
            authorEmail: "developer@example.invalid",
            date: "2026/08/16 10:00",
            decorations: "HEAD -> main, origin/main",
          },
        ],
        hasMore: true,
      },
    );

    expect(result).toEqual({
      references: [
        {
          fullName: "refs/heads/main",
          shortName: "main",
          kind: "local",
          isCurrent: true,
          upstreamShortName: "origin/main",
        },
      ],
      recentReferences: [
        {
          fullName: "refs/heads/main",
          shortName: "main",
          kind: "local",
          isCurrent: true,
          upstreamShortName: "origin/main",
        },
      ],
      commits: [
        {
          hash: "abc123",
          shortHash: "abc123",
          parentHashes: ["parent123"],
          message: "First commit",
          author: "Developer",
          email: "developer@example.invalid",
          date: "2026/08/16 10:00",
          decorations: "HEAD -> main, origin/main",
        },
      ],
      hasMore: true,
    });
  });

  test("defaults missing history fields to an exhausted empty snapshot", () => {
    expect(adaptCoreResult<GitHistorySnapshot>("git_log", undefined, {})).toEqual({
      references: [],
      recentReferences: [],
      commits: [],
      hasMore: false,
    });
  });
});
