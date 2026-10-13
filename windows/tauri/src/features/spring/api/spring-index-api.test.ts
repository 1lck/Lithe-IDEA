import { beforeEach, describe, expect, mock, test } from "bun:test";
import { requestSpringIndex } from "./spring-index-api";
import { classifySpringIndexError } from "../utils/spring-index-error";

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
    }, executeCore);

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
    }, executeCore);
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
    }, executeCore);
    expect(malformed.endpoints).toEqual([]);
  });
});

// Match the actual error envelope emitted by Core's Spring root validation.
test("a missing Spring root is classified from the native response", async () => {
  executeCore.mockResolvedValueOnce({
    id: "request", ok: false,
    error: { code: "invalid_request", message: "Spring index root must be an existing absolute directory" },
  });
  const request = requestSpringIndex({
    root: "D:/fixture/missing", paths: [], refreshDependencyMetadata: false,
  }, executeCore);
  const failure = await request.catch((error) => classifySpringIndexError(error, "D:/fixture/missing"));
  expect(failure).toMatchObject({ category: "rootUnavailable" });
});
