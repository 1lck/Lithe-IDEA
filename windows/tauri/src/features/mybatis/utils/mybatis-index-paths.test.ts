import { describe, expect, test } from "bun:test";
import { editAffectsMybatisIndex, hasMybatisMapperCandidate } from "./mybatis-index-paths";

describe("MyBatis edit invalidation", () => {
  test("Java edits remain eligible before the first pair and after the last pair disappears", () => {
    // Pair membership is deliberately absent from the invalidation input: a
    // method renamed away and restored must trigger both rebuilds.
    const mapper = "C:/work/shop/src/UserMapper.java";
    expect(editAffectsMybatisIndex(mapper)).toBe(true);
    expect(editAffectsMybatisIndex("C:/work/shop/src/NewMapper.JAVA")).toBe(true);
  });

  test("mapper XML is eligible but Maven metadata and unrelated documents are not", () => {
    expect(editAffectsMybatisIndex("C:/work/shop/Mapper.xml")).toBe(true);
    expect(editAffectsMybatisIndex("C:/work/shop/pom.xml")).toBe(false);
    expect(editAffectsMybatisIndex("C:/work/shop/README.md")).toBe(false);
  });
});

describe("MyBatis mapper candidates", () => {
  test("Java-only workspaces skip native indexing", () => {
    expect(hasMybatisMapperCandidate(["src/A.java", "src/B.java"], {})).toBe(false);
    expect(hasMybatisMapperCandidate([], { "src/A.java": "interface A {}" })).toBe(false);
  });

  test("a mapper XML on disk or only in an unsaved buffer requires indexing", () => {
    expect(hasMybatisMapperCandidate(["src/A.java", "mapper/A.XML"], {})).toBe(true);
    expect(hasMybatisMapperCandidate(["src/A.java"], { "mapper/A.xml": "<mapper/>" })).toBe(true);
  });
});
