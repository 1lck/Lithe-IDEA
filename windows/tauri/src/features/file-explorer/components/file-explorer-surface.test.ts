import { expect, test } from "bun:test";

function sourceSection(source: string, start: string, end: string) {
  return source.slice(source.indexOf(start), source.indexOf(end));
}

test("file explorer chrome uses the editor background token", async () => {
  const sidebarSource = await Bun.file(
    new URL("../../../ui/sidebar.tsx", import.meta.url),
  ).text();
  const fileExplorerSource = await Bun.file(
    new URL("./file-explorer-pane.tsx", import.meta.url),
  ).text();
  const fileExplorerStyles = await Bun.file(
    new URL("../styles/file-explorer-tree.css", import.meta.url),
  ).text();

  const panel = sourceSection(
    sidebarSource,
    "export function SidebarPanel",
    "export function SidebarTitleBar",
  );
  const toolbar = sourceSection(
    sidebarSource,
    "export function SidebarToolbar",
    "export const SidebarFooter",
  );
  const header = sourceSection(
    sidebarSource,
    "export function SidebarHeader",
    "export function SidebarComposerBody",
  );

  for (const chrome of [panel, toolbar, header]) {
    expect(chrome).toContain("bg-background");
    expect(chrome).not.toContain("bg-surface");
  }
  const fileExplorerHeaderStyles = sourceSection(
    fileExplorerStyles,
    ".file-explorer-header {",
    ".file-explorer-header-title",
  );
  expect(fileExplorerHeaderStyles).toContain("background-color: var(--background)");
  expect(fileExplorerHeaderStyles).not.toContain("background-color: var(--surface)");
  expect(fileExplorerSource).toContain('<SidebarPanel className="relative">');
});
