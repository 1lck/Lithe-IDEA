import { expect, test } from "bun:test";
import { settingsSearchIndex } from "../config/search-index";
import { scoreSettingSearchRecord } from "./settings-search";

test("run configuration searches target Settings rather than project toolchain defaults", () => {
  const record = settingsSearchIndex.find((entry) => entry.id === "run-configurations");
  expect(record?.tab).toBe("run");
  if (!record) throw new Error("Missing run settings search entry");
  for (const query of ["运行配置", "启动参数", "环境变量", "service", "working directory"]) {
    expect(scoreSettingSearchRecord(query, record)).toBeGreaterThan(0);
  }
});
