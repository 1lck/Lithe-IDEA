import { beforeEach, describe, expect, mock, test } from "bun:test";

const executeCore = mock(async (): Promise<any> => ({
  id: "request",
  ok: true as const,
  data: {
    properties: [],
    values: [],
    propertyReferences: [],
    beans: [],
    injections: [],
    endpoints: [],
  },
}));
const cancelCoreOperation = mock(async () => true);

mock.module("@/core/lithe-core-client", () => ({ executeCore, cancelCoreOperation }));

const { requestSpringIndex } = await import("./spring-index-api");

beforeEach(() => {
  executeCore.mockClear();
});

describe("requestSpringIndex", () => {
  test("preserves endpoint fields and deterministic order", async () => {
    const endpoints = [
      {
        id: "controller:12:GET:/api/first",
        httpMethods: ["GET"],
        route: "/api/first",
        controller: "FirstController",
        method: "first",
        path: "src/main/java/com/example/FirstController.java",
        line: 12,
        column: 3,
      },
      {
        id: "controller:20:POST:/api/second",
        httpMethods: ["POST"],
        route: "/api/second",
        controller: "SecondController",
        method: "second",
        path: "src/main/java/com/example/SecondController.java",
        line: 20,
        column: 3,
      },
    ];
    executeCore.mockResolvedValueOnce({
      id: "request",
      ok: true,
      data: {
        properties: [],
        values: [],
        propertyReferences: [],
        beans: [],
        injections: [],
        endpoints,
      },
    });

    const result = await requestSpringIndex({
      root: "D:/workspace",
      paths: ["src/main/java/com/example/FirstController.java"],
      refreshDependencyMetadata: false,
    });

    expect(result.endpoints).toEqual(endpoints);
  });

  test("normalizes omitted or malformed endpoint collections to an empty array", async () => {
    executeCore.mockResolvedValueOnce({
      id: "request",
      ok: true,
      data: {
        properties: [],
        values: [],
        propertyReferences: [],
        beans: [],
        injections: [],
      },
    });
    const omitted = await requestSpringIndex({
      root: "D:/workspace",
      paths: [],
      refreshDependencyMetadata: false,
    });
    expect(omitted.endpoints).toEqual([]);

    executeCore.mockResolvedValueOnce({
      id: "request",
      ok: true,
      data: {
        properties: [],
        values: [],
        propertyReferences: [],
        beans: [],
        injections: [],
        endpoints: null,
      },
    });
    const malformed = await requestSpringIndex({
      root: "D:/workspace",
      paths: [],
      refreshDependencyMetadata: false,
    });
    expect(malformed.endpoints).toEqual([]);
  });
});
