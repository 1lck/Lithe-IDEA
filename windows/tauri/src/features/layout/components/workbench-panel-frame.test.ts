import { expect, test } from "bun:test";

test("workbench keeps the Project divider without outer horizontal or editor-to-rail seams", async () => {
  const layoutSource = await Bun.file(new URL("./main-layout.tsx", import.meta.url)).text();
  const resizablePaneSource = await Bun.file(
    new URL("./resizable-pane.tsx", import.meta.url),
  ).text();
  const pluginRailSource = await Bun.file(
    new URL("./plugin-activity-rail.tsx", import.meta.url),
  ).text();
  const bottomPaneSource = await Bun.file(
    new URL("./bottom-pane/bottom-pane.tsx", import.meta.url),
  ).text();
  const footerSource = await Bun.file(new URL("./footer/footer.tsx", import.meta.url)).text();
  const titleBarSource = await Bun.file(
    new URL("../../window/components/title-bar/title-bar.tsx", import.meta.url),
  ).text();

  expect(layoutSource).toContain(
    'className="lithe-glass-island relative min-h-0 flex-1 overflow-hidden rounded-xl border-border border-l bg-background"',
  );
  expect(resizablePaneSource).toContain(
    '!hidden && position === "left" && "mr-(--lithe-workbench-gap)"',
  );
  expect(resizablePaneSource).toContain(
    '!hidden && position === "right" && "ml-(--lithe-workbench-gap)"',
  );
  expect(resizablePaneSource).toContain(
    '!hidden && "rounded-xl border-border border-x"',
  );
  expect(pluginRailSource).toContain(
    'className="lithe-plugin-activity-rail flex w-9.5 shrink-0 flex-col items-center rounded-r-xl border-border border-r bg-surface pt-1"',
  );
  expect(pluginRailSource).not.toContain('ml-(--lithe-workbench-gap)');
  expect(pluginRailSource).not.toContain("border-l");
  expect(bottomPaneSource).toContain(
    'rounded-xl border-border/70 border-t border-l bg-background',
  );
  expect(titleBarSource).toContain(
    'gap-(--lithe-chrome-gap) bg-surface px-(--lithe-chrome-padding-inline)',
  );
  expect(titleBarSource).not.toContain(
    'gap-(--lithe-chrome-gap) border-border border-b bg-surface',
  );
  expect(footerSource).toContain(
    'className="lithe-footer-bar relative z-20 justify-between gap-2 bg-surface"',
  );
  expect(footerSource).not.toContain("border-t");
  expect(resizablePaneSource).toContain('const totalWidth = hidden ? "0px" : `${width}px`;');
  expect(resizablePaneSource).toContain('contentEl.style.width = `${currentWidth}px`;');
});
