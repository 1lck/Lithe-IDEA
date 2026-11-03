import { expect, test } from "bun:test";

test("expanded compact menu replaces its toggle with an open File menu", async () => {
  const menuSource = await Bun.file(new URL("./window-menu-bar.tsx", import.meta.url)).text();
  const titleBarSource = await Bun.file(
    new URL("./title-bar/title-bar.tsx", import.meta.url),
  ).text();
  const primitiveSource = await Bun.file(
    new URL("../../../ui/menubar.tsx", import.meta.url),
  ).text();

  expect(menuSource).toContain("compactExpanded");
  expect(menuSource).toContain('"h-full w-max flex-nowrap rounded-none border-none');
  expect(menuSource).not.toContain("absolute top-full left-0");
  expect(menuSource).toContain(
    'ref={compactExpanded && menuName === "File" ? firstMenuTriggerRef : undefined}',
  );
  expect(titleBarSource).toContain("!showCompactMenuBar ? projectControls : null");
  expect(titleBarSource).toContain("{showCompactMenuBar ? (");
  expect(titleBarSource).toContain('setMenuBarActiveMenu("File")');
  expect(titleBarSource).toContain("onClick={handleCompactMenuOpen}");
  expect(menuSource).toContain("firstMenuTriggerRef.current?.focus()");
  expect(primitiveSource).toContain("h-5 shrink-0 select-none items-center whitespace-nowrap");
});

test("File menu offers Settings with a gear icon directly above Close Tab", async () => {
  const menuSource = await Bun.file(new URL("./window-menu-bar.tsx", import.meta.url)).text();

  const settingsItem = menuSource.search(/menu_open_settings"\)\}>\s*<span/);
  const closeTabItem = menuSource.indexOf('handleClickEmit("menu_close_tab")');
  const quitItem = menuSource.indexOf("requestApplicationQuit()");

  expect(settingsItem).toBeGreaterThan(-1);
  expect(settingsItem).toBeLessThan(closeTabItem);
  expect(closeTabItem).toBeLessThan(quitItem);
  expect(menuSource).toContain("<SettingsIcon");
  expect(menuSource).toContain('t("menu.settings")');
});
