import { expect, test } from "bun:test";
import { getSemanticFileIconLookupName } from "./file-icon-semantics";

test("IDEA Icons use reserved semantic lookups without affecting other themes", () => {
  expect(getSemanticFileIconLookupName("idea-icons", "Example.java", "java.class")).toBe(
    "\0lithe:java.class",
  );
  expect(getSemanticFileIconLookupName("idea-icons", "java", "folder.source-root")).toBe(
    "\0lithe:folder.source-root",
  );
  expect(getSemanticFileIconLookupName("material-icons", "Example.java", "java.class")).toBe(
    "Example.java",
  );
  expect(getSemanticFileIconLookupName("idea-icons", "Example.java", null)).toBe("Example.java");
});
