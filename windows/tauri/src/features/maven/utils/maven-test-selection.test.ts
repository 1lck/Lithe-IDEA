import { describe, expect, test } from "bun:test";
import {
  createMavenTestSelector,
  javaTestMethodAtLine,
  normalizeMavenTestMethod,
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

  test("matches only lines inside Core-provided test method ranges", () => {
    const methods = [
      { name: "fast", line: 1, endLine: 3 },
      { name: "slow", line: 7, endLine: 10 },
    ];
    expect(javaTestMethodAtLine(methods, 2)).toEqual({
      name: "fast",
      line: 1,
      endLine: 3,
    });
    expect(javaTestMethodAtLine(methods, 0)).toBeNull();
    expect(javaTestMethodAtLine(methods, 5)).toBeNull();
    expect(javaTestMethodAtLine(methods, 9)?.name).toBe("slow");
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
