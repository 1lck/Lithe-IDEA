import { expect, test } from "bun:test";
import { getMavenPomChangePath, getWorkspaceRootForChange } from "./file-watcher-listener";

test("returns workspace-relative Maven descriptors from the active Windows workspace", () => {
  expect(getMavenPomChangePath("D:\\work\\pom.xml", "D:\\work")).toBe("pom.xml");
  expect(getMavenPomChangePath("D:\\work\\module\\POM.XML", "D:\\work")).toBe("module/POM.XML");
});

test("rejects Maven descriptors from another workspace or a sibling path", () => {
  expect(getMavenPomChangePath("D:\\work-b\\pom.xml", "D:\\work-a")).toBeNull();
  expect(getMavenPomChangePath("D:\\workspace-copy\\pom.xml", "D:\\workspace")).toBeNull();
  expect(getMavenPomChangePath("D:\\workspace\\module\\build.gradle", "D:\\workspace")).toBeNull();
});

test("routes nested changes to the most specific workspace root", () => {
  expect(
    getWorkspaceRootForChange("D:\\work\\module\\src\\Main.java", "D:\\work", [
      "D:\\work",
      "D:\\work\\module",
    ]),
  ).toBe("D:\\work\\module");
});

test("rejects changes outside every workspace root", () => {
  expect(
    getWorkspaceRootForChange("D:\\unrelated\\Main.java", "D:\\work", [
      "D:\\work",
      "E:\\shared",
    ]),
  ).toBeNull();
});
