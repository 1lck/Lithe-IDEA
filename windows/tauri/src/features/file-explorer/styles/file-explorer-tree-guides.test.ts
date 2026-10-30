import { expect, test } from "bun:test";

test("file tree indent guides reveal without changing their interaction geometry", async () => {
  const styles = await Bun.file(new URL("./file-explorer-tree.css", import.meta.url)).text();

  expect(styles).toContain(
    ".file-tree-container[data-guide-hover] [data-sidebar-tree-row] .file-tree-guide",
  );
  expect(styles).toContain(
    ".file-tree-container[data-guide-focus] [data-sidebar-tree-row] .file-tree-guide",
  );
  // :has() selectors here restyled the whole tree on every focus change.
  expect(styles).not.toContain(":has(:focus-visible)");
  expect(styles).toContain("transition: opacity var(--app-duration-fast) var(--app-ease-smooth)");
  expect(styles).toMatch(
    /\.file-tree-container \[data-sidebar-tree-row\] \.file-tree-guide \{[^}]*width: 7px;[^}]*opacity: 0;[^}]*pointer-events: auto;/s,
  );
});
