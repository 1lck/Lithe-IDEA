import { expect, test } from "bun:test";

test("right activity rail opens the real singleton Extensions buffer", async () => {
  const railSource = await Bun.file(
    new URL("./plugin-activity-rail.tsx", import.meta.url),
  ).text();
  const layoutSource = await Bun.file(new URL("./main-layout.tsx", import.meta.url)).text();

  expect(railSource).toContain(
    "const openExtensionsBuffer = useBufferStore.use.actions().openExtensionsBuffer;",
  );
  expect(railSource).toContain('buffer.type === "extensions"');
  expect(railSource).toContain('const extensionsLabel = t("extensions.title");');
  expect(railSource).toContain("aria-pressed={isExtensionsActive}");
  expect(railSource).toContain("onClick={openExtensionsBuffer}");
  expect(railSource).not.toContain("useState");
  expect(layoutSource).toContain("<PluginActivityRail />");
});

test("right activity rail reserves only the current Extensions entry", async () => {
  const railSource = await Bun.file(
    new URL("./plugin-activity-rail.tsx", import.meta.url),
  ).text();
  const transparencyStyles = await Bun.file(
    new URL("../../../styles/window-transparency.css", import.meta.url),
  ).text();

  expect(railSource).toContain(
    'className="lithe-plugin-activity-rail flex w-9.5 shrink-0 flex-col items-center rounded-r-xl border-border border-r bg-surface pt-1"',
  );
  expect(railSource).toContain('<PuzzlePieceIcon className="size-4.5" />');
  expect(railSource.match(/<Button/g)).toHaveLength(1);
  expect(transparencyStyles).toContain(".lithe-plugin-activity-rail");
});
