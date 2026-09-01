import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, test } from "bun:test";
import { formatGitTrackingCount, GitTrackingCounts } from "./git-tracking-counts";

describe("Git tracking counts", () => {
  test("caps large values without hiding either direction", () => {
    const markup = renderToStaticMarkup(
      createElement(GitTrackingCounts, {
        ahead: 53,
        behind: 132,
        aheadLabel: "53 commits ahead",
        behindLabel: "132 commits behind",
      }),
    );

    expect(markup).toContain(">↙</span>99+");
    expect(markup).toContain(">↗</span>53");
    expect(markup).toContain("text-info");
    expect(markup).toContain("text-git-added");
  });

  test("hides synchronized branches", () => {
    expect(renderToStaticMarkup(createElement(GitTrackingCounts, {}))).toBe("");
  });

  test("can render only directional arrows for the current branch surface", () => {
    const markup = renderToStaticMarkup(
      createElement(GitTrackingCounts, {
        ahead: 53,
        behind: 132,
        showCounts: false,
      }),
    );

    expect(markup).toContain(">↙</span>");
    expect(markup).toContain(">↗</span>");
    expect(markup).not.toContain("53");
    expect(markup).not.toContain("99+");
  });

  test("normalizes invalid and fractional counts", () => {
    expect(formatGitTrackingCount(Number.NaN)).toBe("0");
    expect(formatGitTrackingCount(3.9)).toBe("3");
  });
});
