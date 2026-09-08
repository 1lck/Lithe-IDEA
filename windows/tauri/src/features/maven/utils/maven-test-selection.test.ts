import { describe, expect, test } from "bun:test";
import {
  createMavenTestSelector,
  javaTestMethodAtLine,
  normalizeMavenTestMethod,
  projectJavaTestMethods,
  resolveMavenTestTarget,
} from "./maven-test-selection";
import type { MavenProject } from "../types/maven.types";

const projectWithoutSourceRoots: MavenProject = {
  relativePath: "reactor",
  groupId: "dev.lithe",
  artifactId: "demo",
  version: "1.0.0",
  packaging: "pom",
  sourceRoots: [],
  hasWrapper: true,
  profiles: [],
  modules: [
    {
      relativePath: "service",
      groupId: "dev.lithe",
      artifactId: "service",
      version: "1.0.0",
      packaging: "jar",
      sourceRoots: [],
      modules: [],
    },
  ],
};

describe("Maven test selection", () => {
  test("normalizes JUnit selectors without accepting option injection", () => {
    expect(normalizeMavenTestMethod(" additionIsCorrect() ")).toBe("additionIsCorrect");
    expect(createMavenTestSelector("com.example.CalculatorTest", "additionIsCorrect")).toBe(
      "com.example.CalculatorTest#additionIsCorrect",
    );
    expect(createMavenTestSelector("-DskipTests", "additionIsCorrect")).toBeNull();
    expect(createMavenTestSelector("com.example.CalculatorTest", "bad method")).toBeNull();
  });

  test("projects one-based Core method ranges for the Windows editor", () => {
    const methods = projectJavaTestMethods([
      { name: "additionIsCorrect", line: 7, endLine: 7 },
      { name: "subtracts", line: 10, endLine: 13 },
    ]);

    expect(methods).toEqual([
      { name: "additionIsCorrect", line: 6, endLine: 6 },
      { name: "subtracts", line: 9, endLine: 12 },
    ]);
    expect(javaTestMethodAtLine(methods, 6)?.name).toBe("additionIsCorrect");
    expect(javaTestMethodAtLine(methods, 8)).toBeNull();
    expect(javaTestMethodAtLine(methods, 11)?.name).toBe("subtracts");
  });

  test("rejects malformed method records returned across the Core boundary", () => {
    expect(
      projectJavaTestMethods([
        { name: "valid", line: 2, endLine: 3 },
        { name: "bad method", line: 4, endLine: 4 },
        { name: "zeroBased", line: 0, endLine: 1 },
        { name: "backwards", line: 8, endLine: 7 },
        { name: "valid", line: 10, endLine: 10 },
      ]),
    ).toEqual([{ name: "valid", line: 1, endLine: 2 }]);
  });

  test("resolves a nested reactor module from a conventional test path", () => {
    expect(
      resolveMavenTestTarget(
        "D:/work/reactor/service/src/test/java/com/example/CalculatorTest.java",
        "D:/work",
        projectWithoutSourceRoots,
      ),
    ).toEqual({ className: "com.example.CalculatorTest", module: "service" });
  });
});
