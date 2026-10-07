import { describe, expect, test } from "bun:test";
import { createTranslator } from "@/i18n/locale";
import { formatNotificationMessage } from "./notification-formatters";

describe("notification message formatting", () => {
  test("appends the occurrence count from the second appearance", () => {
    const english = createTranslator("en-US");

    expect(formatNotificationMessage({ message: "Build failed", count: 1 }, english)).toBe(
      "Build failed",
    );
    expect(formatNotificationMessage({ message: "Build failed", count: 2 }, english)).toBe(
      "Build failed (2)",
    );
    expect(formatNotificationMessage({ message: "Build failed", count: 12 }, english)).toBe(
      "Build failed (12)",
    );
  });

  test("uses full-width parentheses for Simplified Chinese", () => {
    const simplifiedChinese = createTranslator("zh-CN");

    expect(formatNotificationMessage({ message: "构建失败", count: 1 }, simplifiedChinese)).toBe(
      "构建失败",
    );
    expect(formatNotificationMessage({ message: "构建失败", count: 2 }, simplifiedChinese)).toBe(
      "构建失败（2）",
    );
  });
});
