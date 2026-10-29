import { describe, expect, test } from "bun:test";
import type { MybatisIndex, MybatisStatement } from "../types/mybatis.types";
import { editAffectsMybatisIndex } from "./mybatis-index-paths";

const root = "C:\\work\\shop";
const statement = (javaPath: string): MybatisStatement => ({
  id: `demo.UserMapper#find:${javaPath}`,
  namespace: "demo.UserMapper",
  statementId: "find",
  kind: "select",
  javaPath,
  javaLine: 3,
  javaColumn: 5,
  javaEndLine: 3,
  javaEndColumn: 9,
  xmlPath: "src/main/resources/mapper/UserMapper.xml",
  xmlLine: 1,
  xmlColumn: 1,
  xmlEndColumn: 5,
});

describe("MyBatis index edits", () => {
  const index: MybatisIndex = { statements: [statement("src/main/java/demo/UserMapper.java")] };

  test("an edit to a paired mapper interface or to mapper XML reindexes", () => {
    expect(
      editAffectsMybatisIndex(`${root}\\src\\main\\java\\demo\\UserMapper.java`, root, index),
    ).toBe(true);
    expect(
      editAffectsMybatisIndex(`${root}\\src\\main\\resources\\mapper\\OrderMapper.xml`, root, index),
    ).toBe(true);
  });

  test("an edit to any other Java file, pom.xml or a non-source file does not", () => {
    expect(
      editAffectsMybatisIndex(`${root}\\src\\main\\java\\demo\\UserService.java`, root, index),
    ).toBe(false);
    expect(editAffectsMybatisIndex(`${root}\\pom.xml`, root, index)).toBe(false);
    expect(editAffectsMybatisIndex(`${root}\\README.md`, root, index)).toBe(false);
  });
});
