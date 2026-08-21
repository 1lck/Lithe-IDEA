import { expect, test } from "bun:test";

test("compact floating menu keeps translated labels on one row", async () => {
  const menuSource = await Bun.file(new URL("./window-menu-bar.tsx", import.meta.url)).text();
  const primitiveSource = await Bun.file(
    new URL("../../../ui/menubar.tsx", import.meta.url),
  ).text();

  expect(menuSource).toContain('"absolute top-full left-0 mt-1 w-max"');
  expect(menuSource).toContain('"h-auto w-max flex-nowrap rounded-2xl');
  expect(primitiveSource).toContain("h-5 shrink-0 select-none items-center whitespace-nowrap");
});
