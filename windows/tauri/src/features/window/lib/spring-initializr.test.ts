import { expect, test } from "bun:test";
import { parseInitializrMetadata } from "./spring-initializr";

test("accepts server-provided versions instead of embedding an ageing Boot version", () => {
  const metadata = {
    bootVersion: {
      default: "test-release",
      values: [{ id: "test-release", name: "Test release" }],
    },
    javaVersion: { default: "test-java", values: [{ id: "test-java", name: "Test JDK" }] },
    dependencies: { values: [{ name: "Web", values: [{ id: "web", name: "Spring Web" }] }] },
  };
  expect(parseInitializrMetadata(metadata)).toEqual(metadata);
  expect(() =>
    parseInitializrMetadata({ ...metadata, javaVersion: { default: "missing", values: [] } }),
  ).toThrow();
  expect(() => parseInitializrMetadata("unavailable")).toThrow();
});
