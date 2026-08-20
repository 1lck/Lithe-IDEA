import { expect, test } from "bun:test";
import type { FileEntry } from "@/features/file-system/types/app.types";
import { buildVisibleFileTreeRows } from "./visible-file-tree-rows";

function directory(name: string, path: string, children: FileEntry[] = []): FileEntry {
  return { name, path, isDir: true, children };
}

test("compact folders preserve Maven source roots and compact packages with dots", () => {
  const root = "D:\\project";
  const javaRoot = `${root}\\src\\main\\java`;
  const packageRoot = `${javaRoot}\\com`;
  const packageLeaf = `${packageRoot}\\example`;
  const files = [
    directory("project", root, [
      directory("src", `${root}\\src`, [
        directory("main", `${root}\\src\\main`, [
          directory("java", javaRoot, [
            directory("com", packageRoot, [directory("example", packageLeaf)]),
          ]),
          directory("resources", `${root}\\src\\main\\resources`),
        ]),
        directory("test", `${root}\\src\\test`),
      ]),
      { name: "pom.xml", path: `${root}\\pom.xml`, isDir: false },
    ]),
  ];
  const expandedPaths = new Set([
    root,
    `${root}\\src`,
    `${root}\\src\\main`,
    javaRoot,
    packageRoot,
    packageLeaf,
  ]);

  const rows = buildVisibleFileTreeRows(files, expandedPaths, { compactFolders: true });
  const sourceRootRow = rows.find((row) => row.file.path === javaRoot);
  const packageRow = rows.find((row) => row.file.path === packageLeaf);

  expect(sourceRootRow?.displayName).toBeUndefined();
  expect(sourceRootRow?.semanticKind).toBe("folder.source-root");
  expect(packageRow?.displayName).toBe("com.example");
  expect(packageRow?.semanticKind).toBe("folder.package");
});

test("compact package rows stop before an invalid package directory", () => {
  const root = "D:\\project";
  const javaRoot = `${root}\\src\\main\\java`;
  const packageRoot = `${javaRoot}\\com`;
  const invalidChild = `${packageRoot}\\not-a-package`;
  const files = [
    directory("project", root, [
      directory("src", `${root}\\src`, [
        directory("main", `${root}\\src\\main`, [
          directory("java", javaRoot, [
            directory("com", packageRoot, [directory("not-a-package", invalidChild)]),
          ]),
        ]),
      ]),
      { name: "pom.xml", path: `${root}\\pom.xml`, isDir: false },
    ]),
  ];
  const expandedPaths = new Set([
    root,
    `${root}\\src`,
    `${root}\\src\\main`,
    javaRoot,
    packageRoot,
  ]);

  const rows = buildVisibleFileTreeRows(files, expandedPaths, { compactFolders: true });

  expect(rows.find((row) => row.file.path === packageRoot)?.semanticKind).toBe("folder.package");
  expect(rows.find((row) => row.file.path === packageRoot)?.displayName).toBeUndefined();
  expect(rows.find((row) => row.file.path === invalidChild)?.depth).toBeGreaterThan(
    rows.find((row) => row.file.path === packageRoot)?.depth ?? -1,
  );
});

test("empty directory semantics preserve the original compact-folder projection", () => {
  const root = "D:\\project";
  const javaRoot = `${root}\\src\\main\\java`;
  const packageLeaf = `${javaRoot}\\com\\example`;
  const files = [
    directory("project", root, [
      directory("src", `${root}\\src`, [
        directory("main", `${root}\\src\\main`, [
          directory("java", javaRoot, [
            directory("com", `${javaRoot}\\com`, [directory("example", packageLeaf)]),
          ]),
        ]),
      ]),
      { name: "pom.xml", path: `${root}\\pom.xml`, isDir: false },
    ]),
  ];
  const expandedPaths = new Set([
    root,
    `${root}\\src`,
    `${root}\\src\\main`,
    javaRoot,
    `${javaRoot}\\com`,
    packageLeaf,
  ]);

  const rows = buildVisibleFileTreeRows(files, expandedPaths, {
    compactFolders: true,
    directorySemantics: new Map(),
  });

  expect(rows.find((row) => row.file.path === packageLeaf)?.displayName).toBe(
    "src/main/java/com/example",
  );
  expect(rows.find((row) => row.file.path === packageLeaf)?.semanticKind).toBeUndefined();
});
