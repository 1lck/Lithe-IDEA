import { describe, expect, test } from "bun:test";
import type { SpringIndex } from "../types/spring.types";
import { collectSpringIndexPaths, isSpringConfigurationPath, isSpringIndexPath } from "./spring-index-paths";
import { resolveSpringDefinitions, resolveSpringReferences } from "./spring-navigation";

const ROOT = "C:/work/demo";

const index: SpringIndex = {
  properties: [
    {
      name: "server.port",
      sourcePath: "src/main/java/com/demo/ServerProperties.java",
      sourceLine: 8,
      sourceColumn: 5,
    },
  ],
  values: [
    {
      key: "server.port",
      value: "8080",
      path: "src/main/resources/application.yml",
      line: 2,
      column: 3,
      overridesBaseValue: false,
      targetPath: "src/main/java/com/demo/ServerProperties.java",
      targetLine: 8,
      targetColumn: 5,
    },
  ],
  propertyReferences: [
    {
      key: "server.port",
      path: "src/main/java/com/demo/ApiController.java",
      line: 14,
      column: 12,
    },
  ],
  beans: [
    {
      id: "userService",
      name: "userService",
      typeName: "com.demo.UserService",
      path: "src/main/java/com/demo/UserService.java",
      line: 6,
      column: 1,
      kind: "component",
    },
  ],
  injections: [
    {
      path: "src/main/java/com/demo/ApiController.java",
      line: 10,
      column: 5,
      typeName: "com.demo.UserService",
      beanIds: ["userService"],
    },
  ],
};

describe("Spring index path filters", () => {
  test("keeps Java, application config, and metadata files", () => {
    expect(isSpringIndexPath("C:/work/App.java")).toBe(true);
    expect(isSpringConfigurationPath("C:/work/src/main/resources/application-dev.yml")).toBe(true);
    expect(isSpringIndexPath("C:/work/README.md")).toBe(false);
    expect(
      collectSpringIndexPaths(
        [
          "C:/work/demo/src/main/java/App.java",
          "C:/work/demo/src/main/resources/application.yml",
          "C:/work/demo/README.md",
        ],
        ROOT,
      ),
    ).toEqual(["src/main/java/App.java", "src/main/resources/application.yml"]);
  });
});

describe("Spring definition navigation", () => {
  test("jumps from a configuration value to the Java declaration and @Value uses", () => {
    const locations = resolveSpringDefinitions(
      index,
      ROOT,
      "C:/work/demo/src/main/resources/application.yml",
      1,
    );
    expect(locations.map((location) => `${location.filePath}:${location.line}`)).toEqual([
      "C:/work/demo/src/main/java/com/demo/ServerProperties.java:7",
      "C:/work/demo/src/main/java/com/demo/ApiController.java:13",
    ]);
  });

  test("jumps from a @Value reference back to the configuration document", () => {
    const locations = resolveSpringDefinitions(
      index,
      ROOT,
      "C:/work/demo/src/main/java/com/demo/ApiController.java",
      13,
    );
    expect(locations).toEqual([
      {
        filePath: "C:/work/demo/src/main/resources/application.yml",
        line: 1,
        column: 2,
        symbol: "server.port",
      },
    ]);
  });

  test("jumps from an injection point to the matching bean", () => {
    const locations = resolveSpringDefinitions(
      index,
      ROOT,
      "C:/work/demo/src/main/java/com/demo/ApiController.java",
      9,
    );
    expect(locations).toEqual([
      {
        filePath: "C:/work/demo/src/main/java/com/demo/UserService.java",
        line: 5,
        column: 0,
        symbol: "userService",
      },
    ]);
  });
});

describe("Spring reference navigation", () => {
  test("collects the configuration value and every @Value use for the same key", () => {
    const locations = resolveSpringReferences(
      index,
      ROOT,
      "C:/work/demo/src/main/resources/application.yml",
      1,
    );
    expect(locations.map((location) => location.filePath)).toContain(
      "C:/work/demo/src/main/resources/application.yml",
    );
    expect(locations.map((location) => location.filePath)).toContain(
      "C:/work/demo/src/main/java/com/demo/ApiController.java",
    );
  });
});
