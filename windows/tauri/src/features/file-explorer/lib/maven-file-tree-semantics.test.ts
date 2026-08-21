import { describe, expect, test } from "bun:test";
import type { FileEntry } from "@/features/file-system/types/app.types";
import { buildMavenDirectorySemantics } from "./maven-file-tree-semantics";

function directory(name: string, path: string, children: FileEntry[] = []): FileEntry {
  return { name, path, isDir: true, children };
}

function file(name: string, path: string): FileEntry {
  return { name, path, isDir: false };
}

function createMavenTree(root = "D:\\project"): FileEntry[] {
  return [
    directory("project", root, [
      directory("src", `${root}\\src`, [
        directory("main", `${root}\\src\\main`, [
          directory("java", `${root}\\src\\main\\java`, [
            directory("com", `${root}\\src\\main\\java\\com`, [
              directory("example", `${root}\\src\\main\\java\\com\\example`),
            ]),
          ]),
          directory("resources", `${root}\\src\\main\\resources`),
        ]),
        directory("test", `${root}\\src\\test`, [
          directory("java", `${root}\\src\\test\\java`),
          directory("resources", `${root}\\src\\test\\resources`),
        ]),
      ]),
      file("pom.xml", `${root}\\pom.xml`),
    ]),
  ];
}

describe("Maven directory icon semantics", () => {
  test("recognizes standard roots and Java packages in a loaded Maven module", () => {
    const semantics = buildMavenDirectorySemantics(createMavenTree());

    expect(semantics.get("D:\\project\\src\\main\\java")).toBe("folder.source-root");
    expect(semantics.get("D:\\project\\src\\main\\java\\com\\example")).toBe("folder.package");
    expect(semantics.get("D:\\project\\src\\test\\java")).toBe("folder.test-root");
    expect(semantics.get("D:\\project\\src\\main\\resources")).toBe("folder.resources-root");
    expect(semantics.get("D:\\project\\src\\test\\resources")).toBe("folder.test-resources-root");
  });

  test("does not label standard-looking paths without a loaded pom.xml", () => {
    const [root] = createMavenTree();
    root!.children = root!.children?.filter((entry) => entry.name !== "pom.xml");

    expect(buildMavenDirectorySemantics([root!]).size).toBe(0);
  });

  test("does not label invalid Java package directory names", () => {
    const tree = createMavenTree();
    const javaRoot = tree[0]?.children?.[0]?.children?.[0]?.children?.[0];
    javaRoot?.children?.push(
      directory("not-a-package", "D:\\project\\src\\main\\java\\not-a-package"),
    );

    expect(
      buildMavenDirectorySemantics(tree).get("D:\\project\\src\\main\\java\\not-a-package"),
    ).toBeUndefined();
  });

  test("rejects Java keywords while allowing Unicode identifiers", () => {
    const tree = createMavenTree();
    const javaRoot = tree[0]?.children?.[0]?.children?.[0]?.children?.[0];
    javaRoot?.children?.push(
      directory("class", "D:\\project\\src\\main\\java\\class"),
      directory("示例", "D:\\project\\src\\main\\java\\示例"),
    );
    const semantics = buildMavenDirectorySemantics(tree);

    expect(semantics.get("D:\\project\\src\\main\\java\\class")).toBeUndefined();
    expect(semantics.get("D:\\project\\src\\main\\java\\示例")).toBe("folder.package");
  });
});
