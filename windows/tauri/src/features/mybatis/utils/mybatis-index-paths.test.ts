import { describe, expect, test } from "bun:test";
import { editAffectsMybatisIndex } from "./mybatis-index-paths";

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
