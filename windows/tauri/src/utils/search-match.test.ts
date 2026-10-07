import { expect, test } from "bun:test";
import {
  compactSearchText,
  matchesSearchQuery,
  normalizeSearchText,
  scoreSearchQuery,
} from "./search-match";

test("Chinese font queries filter localized family names instead of matching every font", () => {
  expect(normalizeSearchText("微软雅黑")).toBe("微软雅黑");
  expect(matchesSearchQuery("雅黑", ["微软雅黑 (Microsoft YaHei)"])).toBe(true);
  expect(matchesSearchQuery("微软雅黑", ["Consolas"])).toBe(false);
  expect(matchesSearchQuery("yahei", ["微软雅黑", "Microsoft YaHei"])).toBe(true);
  expect(matchesSearchQuery("黑体", ["宋体 (SimSun)"])).toBe(false);
});

test("Unicode letters and shaping marks survive search normalization", () => {
  expect(matchesSearchQuery("メイリオ", ["メイリオ"])).toBe(true);
  expect(matchesSearchQuery("ガ", ["ガ"])).toBe(true);
  expect(matchesSearchQuery("देव", ["देवनागरी"])).toBe(true);
  expect(matchesSearchQuery("東京", ["Consolas"])).toBe(false);
});

test("Latin accent folding, punctuation, case and compact matching stay compatible", () => {
  expect(normalizeSearchText("  CÁSCADIA-Code  ")).toBe("cascadia code");
  expect(compactSearchText("Cascadia Code")).toBe("cascadiacode");
  expect(matchesSearchQuery("cascadiacode", ["Cascadia Code"])).toBe(true);
  expect(matchesSearchQuery("", ["Consolas"])).toBe(true);
  expect(scoreSearchQuery("字体", [{ value: "编辑器字体", weight: 2 }])).toBe(2);
  expect(scoreSearchQuery("字体", [{ value: "Consolas", weight: 2 }])).toBe(0);
});
