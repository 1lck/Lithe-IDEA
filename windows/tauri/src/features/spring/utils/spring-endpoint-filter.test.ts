import { describe, expect, test } from "bun:test";
import type { SpringEndpoint } from "../types/spring.types";
import { filterSpringEndpoints } from "./spring-endpoint-filter";

const endpoints: SpringEndpoint[] = [
  {
    id: "users",
    httpMethods: ["GET"],
    route: "/api/users",
    controller: "UserController",
    method: "listUsers",
    path: "src/main/java/UserController.java",
    line: 20,
    column: 3,
  },
  {
    id: "orders",
    httpMethods: ["POST"],
    route: "/api/orders",
    controller: "OrderController",
    method: "createOrder",
    path: "src/main/java/OrderController.java",
    line: 30,
    column: 3,
  },
];

describe("filterSpringEndpoints", () => {
  test("matches route, controller, method, and HTTP method", () => {
    expect(filterSpringEndpoints(endpoints, "users")).toEqual([endpoints[0]]);
    expect(filterSpringEndpoints(endpoints, "OrderController")).toEqual([endpoints[1]]);
    expect(filterSpringEndpoints(endpoints, "createOrder")).toEqual([endpoints[1]]);
    expect(filterSpringEndpoints(endpoints, "post")).toEqual([endpoints[1]]);
  });

  test("matches HTTP method sets joined with a space", () => {
    const multiMethod = {
      ...endpoints[0],
      id: "multi",
      httpMethods: ["GET", "POST"],
      route: "/api/multi",
    };
    expect(filterSpringEndpoints([multiMethod], "get post")).toEqual([multiMethod]);
  });

  test("is case-insensitive and trims the query", () => {
    expect(filterSpringEndpoints(endpoints, "  UsErS  ")).toEqual([endpoints[0]]);
  });

  test("returns all endpoints for a blank query and none for no match", () => {
    expect(filterSpringEndpoints(endpoints, "   ")).toEqual(endpoints);
    expect(filterSpringEndpoints(endpoints, "missing")).toEqual([]);
  });
});
