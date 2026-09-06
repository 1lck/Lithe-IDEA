import { describe, expect, test } from "bun:test";
import {
  createMavenTestSelector,
  discoverJavaTestMethods,
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

  test("discovers JUnit 4 and JUnit 5 test methods in source order", () => {
    const methods = discoverJavaTestMethods(`
      import org.junit.Test;
      import org.junit.jupiter.api.ParameterizedTest;

      class CalculatorTest {
        @Test
        public void additionIsCorrect() {}

        @ParameterizedTest
        void subtracts(int value) {}
      }
    `);

    expect(methods).toEqual([
      { name: "additionIsCorrect", line: 6 },
      { name: "subtracts", line: 9 },
    ]);
    expect(javaTestMethodAtLine("@Test\nvoid fast() {}", 1)).toEqual({
      name: "fast",
      line: 1,
    });
    expect(javaTestMethodAtLine("@Test\nvoid fast() {}", 0)).toBeNull();
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
