import { describe, expect, test } from "bun:test";
import { createTranslator } from "@/i18n/locale";
import type { MavenDependency } from "../types/maven.types";
import { mavenDependencySubtitle } from "./maven-dependency-subtitle";

const dependency: MavenDependency = {
  modulePath: "service",
  groupId: "org.example",
  artifactId: "managed-lib",
  version: "2.1",
  type: "jar",
  classifier: null,
  scope: "compile",
  resolution: "resolved",
  selectedVersion: null,
  children: [],
};

describe("Maven dependency subtitle", () => {
  test("shows a plain coordinate without annotations", () => {
    expect(mavenDependencySubtitle(dependency, createTranslator("en-US"))).toBe(
      "org.example:2.1:jar [compile]",
    );
  });

  test("keeps every annotation Maven reported, in its own order", () => {
    const annotated: MavenDependency = {
      ...dependency,
      classifier: "tests",
      resolution: "omittedConflict",
      selectedVersion: "3.0",
      premanagedVersion: "0.9.0",
      premanagedScope: "test",
      originalScope: "runtime",
      ignoredScope: "compile",
    };

    expect(mavenDependencySubtitle(annotated, createTranslator("en-US"))).toBe(
      "org.example:2.1:jar:tests [compile] (version managed from 0.9.0; scope managed from test; " +
        "scope updated from runtime; scope not updated to compile; conflict with -> 3.0)",
    );
    expect(mavenDependencySubtitle(annotated, createTranslator("zh-CN"))).toBe(
      "org.example:2.1:jar:tests [compile] (依赖管理前版本为 0.9.0; 依赖管理前 scope 为 test; " +
        "scope 由 runtime 提升; 未提升为 compile scope; 版本冲突，采用 -> 3.0)",
    );
  });

  test("marks a duplicate that dependency management also changed", () => {
    expect(
      mavenDependencySubtitle(
        { ...dependency, resolution: "omittedDuplicate", premanagedVersion: "1.0" },
        createTranslator("en-US"),
      ),
    ).toBe("org.example:2.1:jar [compile] (version managed from 1.0; duplicate omitted)");
  });
});
