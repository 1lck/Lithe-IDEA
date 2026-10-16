import { expect, test } from "bun:test";

test("tab context menu keeps the close group above the other tab actions", async () => {
  const source = await Bun.file(new URL("./tab-context-menu.tsx", import.meta.url)).text();

  const closeIndex = source.indexOf('id: "close",');
  const closeOthersIndex = source.indexOf('id: "close-others",');
  const closeRightIndex = source.indexOf('id: "close-right",');
  const closeSavedIndex = source.indexOf('id: "close-saved",');
  const closeAllIndex = source.indexOf('id: "close-all",');
  const separatorIndex = source.indexOf('id: "sep-close",');
  const pinIndex = source.indexOf('id: "pin",');

  expect(closeIndex).toBeGreaterThan(-1);
  expect(closeOthersIndex).toBeGreaterThan(closeIndex);
  expect(closeRightIndex).toBeGreaterThan(closeOthersIndex);
  expect(closeSavedIndex).toBeGreaterThan(closeRightIndex);
  expect(closeAllIndex).toBeGreaterThan(closeSavedIndex);
  // The close group is the first section, so it must stay above the pin action.
  expect(separatorIndex).toBeGreaterThan(closeAllIndex);
  expect(pinIndex).toBeGreaterThan(separatorIndex);
});

test("tab context menu closes saved tabs through their own callback", async () => {
  const source = await Bun.file(new URL("./tab-context-menu.tsx", import.meta.url)).text();

  const closeSavedIndex = source.indexOf('id: "close-saved",');
  const closeAllIndex = source.indexOf('id: "close-all",');
  expect(closeSavedIndex).toBeGreaterThan(-1);

  const closeSavedEntry = source.slice(closeSavedIndex, closeAllIndex);

  // The entry must reach the store action that skips tabs with unsaved edits,
  // not the "close all" handler, which force-closes every unpinned tab.
  expect(closeSavedEntry).toContain('label: t("tabs.closeSaved"),');
  expect(closeSavedEntry).toContain("onClick: onCloseSaved,");
});
