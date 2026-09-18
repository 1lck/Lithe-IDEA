import { describe, expect, test } from "bun:test";
import {
  discoverProjectRunActions,
  javaTestActionsForFile,
  parseComposerRunActions,
} from "./run-action-discovery";

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

describe("PHP run actions", () => {
  test("turns composer scripts into run actions ordered by intent", () => {
    const actions = parseComposerRunActions(
      JSON.stringify({
        scripts: {
          "db:seed": "php bin/seed.php",
          test: "phpunit",
          dev: "php -S localhost:8000",
        },
      }),
      "/work/api",
    );

    expect(actions.map((action) => action.name)).toEqual(["dev", "test", "db:seed"]);
    expect(actions.every((action) => action.source === "php")).toBe(true);
    expect(actions[0]).toMatchObject({
      command: "composer run dev",
      description: "php -S localhost:8000",
      sourceLabel: "composer.json",
      workingDirectory: "/work/api",
    });
  });

  test("ignores composer manifests without a usable scripts section", () => {
    expect(parseComposerRunActions("not json", "/work/api")).toEqual([]);
    expect(parseComposerRunActions(JSON.stringify({ name: "api" }), "/work/api")).toEqual([]);
    expect(parseComposerRunActions(JSON.stringify({ scripts: { dev: 7 } }), "/work/api")).toEqual([]);
  });

  test("discovers a phpunit action for a PHPUnit project", async () => {
    const files = new Map([
      ["/work/api/composer.json", JSON.stringify({ scripts: { test: "phpunit" } })],
      ["/work/api/phpunit.xml.dist", "<phpunit/>"],
    ]);
    const actions = await discoverProjectRunActions("/work/api", async (path) => {
      const content = files.get(path);
      if (content === undefined) throw new Error(`missing ${path}`);
      return content;
    });

    const commands = actions.map((action) => action.command);
    expect(commands).toContain("composer run test");
    expect(commands).toContain("php vendor/bin/phpunit");
    expect(actions.every((action) => action.source === "php")).toBe(true);
  });

  test("stays quiet for a PHP project without PHPUnit", async () => {
    const files = new Map([
      ["/work/api/composer.json", JSON.stringify({ scripts: { lint: "phpcs" } })],
    ]);
    const actions = await discoverProjectRunActions("/work/api", async (path) => {
      const content = files.get(path);
      if (content === undefined) throw new Error(`missing ${path}`);
      return content;
    });

    expect(actions.map((action) => action.command)).toEqual(["composer run lint"]);
  });
});
