import { expect, test } from "bun:test";
import { getMavenPomChangePath } from "./file-watcher-listener";

test("returns workspace-relative Maven descriptors from the active Windows workspace", () => {
  expect(getMavenPomChangePath("D:\\work\\pom.xml", "D:\\work")).toBe("pom.xml");
  expect(getMavenPomChangePath("D:\\work\\module\\POM.XML", "D:\\work")).toBe("module/POM.XML");
});

test("rejects Maven descriptors from another workspace or a sibling path", () => {
  expect(getMavenPomChangePath("D:\\work-b\\pom.xml", "D:\\work-a")).toBeNull();
  expect(getMavenPomChangePath("D:\\workspace-copy\\pom.xml", "D:\\workspace")).toBeNull();
  expect(getMavenPomChangePath("D:\\workspace\\module\\build.gradle", "D:\\workspace")).toBeNull();
});
