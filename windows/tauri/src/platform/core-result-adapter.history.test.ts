import { describe, expect, test } from "bun:test";
import type {
  GitHistoryPage,
  GitHistorySnapshot,
  GitReferenceSnapshot,
} from "@/features/git/types/git.types";
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
            ahead: 12,
            behind: 3,
          },
        ],
        recentReferences: [
          {
            fullName: "refs/heads/main",
            shortName: "main",
            kind: "local",
            isCurrent: true,
            upstreamShortName: "origin/main",
            ahead: 12,
            behind: 3,
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
          ahead: 12,
          behind: 3,
        },
      ],
      recentReferences: [
        {
          fullName: "refs/heads/main",
          shortName: "main",
          kind: "local",
          isCurrent: true,
          upstreamShortName: "origin/main",
          ahead: 12,
          behind: 3,
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

  test("adapts references independently from commit history", () => {
    expect(
      adaptCoreResult<GitReferenceSnapshot>("git_references", undefined, {
        references: [
          {
            fullName: "refs/heads/main",
            shortName: "main",
            kind: "local",
            isCurrent: true,
          },
        ],
        recentReferences: [],
      }),
    ).toEqual({
      references: [
        {
          fullName: "refs/heads/main",
          shortName: "main",
          kind: "local",
          isCurrent: true,
          upstreamShortName: undefined,
        },
      ],
      recentReferences: [],
    });
  });

  test("preserves the next cursor for an incremental history page", () => {
    expect(
      adaptCoreResult<GitHistoryPage>("git_history_page", undefined, {
        commits: [
          {
            hash: "abc1234",
            parentHashes: [],
            subject: "Page commit",
            authorName: "Developer",
            authorEmail: "developer@example.invalid",
            date: "2026/08/16 10:00",
            decorations: "",
          },
        ],
        nextCursor: "cursor-50",
        hasMore: true,
      }),
    ).toEqual({
      commits: [
        {
          hash: "abc1234",
          shortHash: "abc1234",
          parentHashes: [],
          message: "Page commit",
          author: "Developer",
          email: "developer@example.invalid",
          date: "2026/08/16 10:00",
          decorations: "",
        },
      ],
      nextCursor: "cursor-50",
      hasMore: true,
    });
  });
});
