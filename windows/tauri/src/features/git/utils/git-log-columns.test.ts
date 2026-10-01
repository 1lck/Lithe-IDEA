import { describe, expect, test } from "bun:test";
import {
  GIT_LOG_COLUMN_DEFAULT_WIDTHS,
  clampGitLogColumnWidth,
  normalizeGitLogColumnWidth,
} from "./git-log-columns";

describe("git log column widths", () => {
  test("clamps drag results to a readable range per column", () => {
    expect(clampGitLogColumnWidth("author", 0)).toBe(56);
    expect(clampGitLogColumnWidth("author", 9999)).toBe(360);
    expect(clampGitLogColumnWidth("date", 0)).toBe(72);
    expect(clampGitLogColumnWidth("date", 9999)).toBe(280);
    expect(clampGitLogColumnWidth("author", 140.4)).toBe(140);
  });

  test("restores defaults for missing or corrupt persisted values", () => {
    expect(normalizeGitLogColumnWidth("author", undefined)).toBe(
      GIT_LOG_COLUMN_DEFAULT_WIDTHS.author,
    );
    expect(normalizeGitLogColumnWidth("date", "wide")).toBe(GIT_LOG_COLUMN_DEFAULT_WIDTHS.date);
    expect(normalizeGitLogColumnWidth("date", Number.NaN)).toBe(GIT_LOG_COLUMN_DEFAULT_WIDTHS.date);
    expect(normalizeGitLogColumnWidth("author", 5000)).toBe(360);
  });
});
