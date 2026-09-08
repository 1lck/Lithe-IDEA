import { describe, expect, test } from "bun:test";
import type { MybatisIndex } from "../types/mybatis.types";
import { collectMybatisIndexPaths, isMybatisIndexPath } from "./mybatis-index-paths";
import { resolveMybatisDefinitions } from "./mybatis-navigation";

const ROOT = "C:/work/demo";

const index: MybatisIndex = {
  statements: [
    {
      id: "demo.UserMapper#selectById:src/main/resources/mapper/UserMapper.xml:5",
      namespace: "demo.UserMapper",
      statementId: "selectById",
      kind: "select",
      javaPath: "src/main/java/demo/UserMapper.java",
      javaLine: 9,
      javaColumn: 10,
      javaEndLine: 12,
      xmlPath: "src/main/resources/mapper/UserMapper.xml",
      xmlLine: 5,
      xmlColumn: 17,
    },
  ],
};

describe("MyBatis index path filters", () => {
  test("keeps Java and mapper XML files", () => {
    expect(isMybatisIndexPath("C:/work/UserMapper.java")).toBe(true);
    expect(isMybatisIndexPath("C:/work/src/main/resources/mapper/UserMapper.xml")).toBe(true);
    expect(isMybatisIndexPath("C:/work/pom.xml")).toBe(false);
    expect(isMybatisIndexPath("C:/work/README.md")).toBe(false);
    expect(
      collectMybatisIndexPaths(
        [
          "C:/work/demo/src/main/java/demo/UserMapper.java",
          "C:/work/demo/src/main/resources/mapper/UserMapper.xml",
          "C:/work/demo/pom.xml",
        ],
        ROOT,
      ),
    ).toEqual([
      "src/main/java/demo/UserMapper.java",
      "src/main/resources/mapper/UserMapper.xml",
    ]);
  });
});

describe("MyBatis definition navigation", () => {
  test("jumps from a mapper method to the XML statement", () => {
    const locations = resolveMybatisDefinitions(
      index,
      ROOT,
      "C:/work/demo/src/main/java/demo/UserMapper.java",
      8,
    );
    expect(locations).toEqual([
      {
        filePath: "C:/work/demo/src/main/resources/mapper/UserMapper.xml",
        line: 4,
        column: 16,
        symbol: "selectById",
      },
    ]);
  });

  test("jumps from a later line of a multi-line mapper signature", () => {
    const locations = resolveMybatisDefinitions(
      index,
      ROOT,
      "C:/work/demo/src/main/java/demo/UserMapper.java",
      11,
    );
    expect(locations.map((location) => location.filePath)).toEqual([
      "C:/work/demo/src/main/resources/mapper/UserMapper.xml",
    ]);
  });

  test("jumps from an XML statement back to the mapper method", () => {
    const locations = resolveMybatisDefinitions(
      index,
      ROOT,
      "C:/work/demo/src/main/resources/mapper/UserMapper.xml",
      4,
    );
    expect(locations).toEqual([
      {
        filePath: "C:/work/demo/src/main/java/demo/UserMapper.java",
        line: 8,
        column: 9,
        symbol: "selectById",
      },
    ]);
  });
});
