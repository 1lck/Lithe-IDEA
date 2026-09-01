import { describe, expect, test } from "bun:test";
import { createTranslator } from "@/i18n/locale";
import type { GitOperationState, GitPullResult } from "../types/git.types";
import { getGitPullResultPresentation } from "./git-pull-result-presentation";

const operation: GitOperationState = {
  kind: "rebase",
  reference: "origin/main",
  step: 1,
  total: 2,
  conflictedPaths: ["src/conflict.ts"],
};

describe("Git Pull result presentation", () => {
  test("maps stable results to English user-facing messages", () => {
    const t = createTranslator("en-US");

    expect(getGitPullResultPresentation({ status: "pulled", strategy: "merge" }, t)).toEqual({
      message: "Merged upstream changes successfully.",
      tone: "success",
    });
    expect(
      getGitPullResultPresentation({ status: "blocked", reason: "state-changed" }, t),
    ).toEqual({
      message: "The branch changed while choosing a pull strategy. Review it and try again.",
      tone: "warning",
    });
    expect(
      getGitPullResultPresentation({ status: "failed", stage: "fetch", error: "offline" }, t),
    ).toEqual({ message: "Fetch failed: offline", tone: "error" });
  });

  test("maps the same stable results to Chinese user-facing messages", () => {
    const t = createTranslator("zh-CN");
    const conflict: GitPullResult = { status: "conflict", operation };

    expect(getGitPullResultPresentation({ status: "blocked", reason: "no-upstream" }, t)).toEqual({
      message: "当前分支没有上游分支，请先设置上游分支。",
      tone: "warning",
    });
    expect(getGitPullResultPresentation(conflict, t)).toEqual({
      message: "变基因冲突而停止，请先解决冲突。",
      tone: "warning",
    });
    expect(getGitPullResultPresentation({ status: "failed", stage: "pull" }, t)).toEqual({
      message: "拉取失败：Git 拒绝了此次拉取。",
      tone: "error",
    });
  });

  test("keeps duplicate and cancelled results silent", () => {
    const t = createTranslator("en-US");
    expect(getGitPullResultPresentation({ status: "duplicate" }, t)).toBeNull();
    expect(getGitPullResultPresentation({ status: "cancelled" }, t)).toBeNull();
  });
});
