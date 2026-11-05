import { describe, expect, test } from "bun:test";
import type {
  GitHistoryLocateResult,
  GitHistoryPage,
  GitHistorySnapshot,
  GitReferenceSnapshot,
} from "@/features/git/types/git.types";
import { adaptCoreResult } from "./core-result-adapter";

describe("git history result adaptation", () => {
  test("preserves the resolved commit instant in history and paged results", () => {
    const commit = { hash: "abc", shortHash: "abc", parentHashes: [], subject: "Timezone",
      authorName: "Ada", authorEmail: "ada@example.invalid", date: "2026/09/10 00:30",
      dateUtcOffsetMinutes: 480, dateUnixSeconds: 1788971400, decorations: "" };
    for (const command of ["git_log", "git_history_page"]) {
      const result = adaptCoreResult<GitHistoryPage>(command, undefined, {
        references: [], commits: [commit], hasMore: false,
      });
      expect(result.commits[0]?.dateUtcOffsetMinutes).toBe(480);
      expect(result.commits[0]?.dateUnixSeconds).toBe(1788971400);
    }
  });
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
            peelsToCommit: true,
            isCurrent: true,
            upstreamShortName: "origin/main",
            ahead: 12,
            behind: 3,
          },
          {
            fullName: "refs/tags/tree-tag",
            shortName: "tree-tag",
            kind: "tag",
            peelsToCommit: false,
            isCurrent: false,
          },
        ],
        recentReferences: [
          {
            fullName: "refs/heads/main",
            shortName: "main",
            kind: "local",
            peelsToCommit: true,
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
          peelsToCommit: true,
          isCurrent: true,
          upstreamShortName: "origin/main",
          ahead: 12,
          behind: 3,
        },
        {
          fullName: "refs/tags/tree-tag",
          shortName: "tree-tag",
          kind: "tag",
          peelsToCommit: false,
          isCurrent: false,
          ahead: 0,
          behind: 0,
          upstreamShortName: undefined,
        },
      ],
      recentReferences: [
        {
          fullName: "refs/heads/main",
          shortName: "main",
          kind: "local",
          peelsToCommit: true,
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
            peelsToCommit: true,
            isCurrent: true,
            upstreamShortName: "origin/main",
            ahead: 4,
            behind: 2,
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
          peelsToCommit: true,
          isCurrent: true,
          upstreamShortName: "origin/main",
          ahead: 4,
          behind: 2,
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

  test("adapts a commit locate result with the same commit shape as history pages", () => {
    const result = adaptCoreResult<GitHistoryLocateResult>("git.historyLocate", undefined, {
      found: true,
      commits: [
        {
          hash: "abc1234",
          shortHash: "abc1234",
          parentHashes: ["parent1"],
          subject: "Hit commit",
          authorName: "Developer",
          authorEmail: "developer@example.invalid",
          date: "2026/08/16 10:00",
          dateUtcOffsetMinutes: -300,
          decorations: "",
        },
      ],
      nextCursor: "cursor-2",
      hasMore: true,
      pagesLoaded: 2,
    });

    expect(result).toEqual({
      found: true,
      commits: [
        {
          hash: "abc1234",
          shortHash: "abc1234",
          parentHashes: ["parent1"],
          message: "Hit commit",
          author: "Developer",
          email: "developer@example.invalid",
          date: "2026/08/16 10:00",
          dateUtcOffsetMinutes: -300,
          dateUnixSeconds: undefined,
          decorations: "",
        },
      ],
      nextCursor: "cursor-2",
      hasMore: true,
      pagesLoaded: 2,
    });
    // An exhausted walk reports no hit without inventing fields.
    expect(adaptCoreResult<GitHistoryLocateResult>("git.historyLocate", undefined, {})).toEqual({
      found: false,
      commits: [],
      nextCursor: undefined,
      hasMore: false,
      pagesLoaded: 0,
    });
  });
});
