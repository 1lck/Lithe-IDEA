import { afterEach, describe, expect, test } from "bun:test";
import { markTabActivated, orderTabsForClosing, resetTabRecencyForTests } from "./tab-recency";

const tabs = [{ id: "a" }, { id: "b" }, { id: "c" }];

afterEach(() => {
  resetTabRecencyForTests();
});

describe("tab limit closing order", () => {
  test("closes the least recently used tab first", () => {
    markTabActivated("a");
    markTabActivated("b");
    markTabActivated("c");
    markTabActivated("a");

    expect(orderTabsForClosing(tabs, "leastRecentlyUsed").map((tab) => tab.id)).toEqual([
      "b",
      "c",
      "a",
    ]);
  });

  test("treats never activated tabs as least recently used, in open order", () => {
    markTabActivated("a");

    expect(orderTabsForClosing(tabs, "leastRecentlyUsed").map((tab) => tab.id)).toEqual([
      "b",
      "c",
      "a",
    ]);
  });

  test("keeps open order for the oldest-opened policy", () => {
    markTabActivated("a");

    expect(orderTabsForClosing(tabs, "oldestOpened").map((tab) => tab.id)).toEqual([
      "a",
      "b",
      "c",
    ]);
  });
});
