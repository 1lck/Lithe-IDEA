import { describe, expect, test } from "bun:test";
import { javaTestActionsForFile } from "./run-action-discovery";

describe("Java Maven run actions", () => {
  test("keeps the class action when Core finds no test methods", () => {
    const actions = javaTestActionsForFile("D:/work/CalculatorTest.java", [], (key) => key);

    expect(actions).toHaveLength(1);
    expect(actions[0]?.mavenTest).toEqual({ filePath: "D:/work/CalculatorTest.java" });
  });

  test("adds method actions from Core-provided source ranges", () => {
    const actions = javaTestActionsForFile(
      "D:/work/CalculatorTest.java",
      [{ name: "adds", line: 4, endLine: 8 }],
      (key) => key,
    );

    expect(actions.map((action) => action.mavenTest)).toEqual([
      { filePath: "D:/work/CalculatorTest.java" },
      { filePath: "D:/work/CalculatorTest.java", method: "adds" },
    ]);
    expect(actions[1]?.description).toBe("CalculatorTest.java:5");
  });
});
