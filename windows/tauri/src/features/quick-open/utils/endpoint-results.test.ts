import { describe, expect, test } from "bun:test";
import type { SpringEndpoint } from "@/features/spring/types/spring.types";
import { toQuickOpenEndpointResults } from "./endpoint-results";

const endpoints: SpringEndpoint[] = [
  {
    id: "users",
    httpMethods: ["GET"],
    route: "/api/users",
    controller: "UserController",
    method: "listUsers",
    path: "src/main/java/UserController.java",
    line: 12,
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

describe("toQuickOpenEndpointResults", () => {
  test("maps matched endpoints to one-based controller navigation locations", () => {
    const result = toQuickOpenEndpointResults(endpoints, "C:/work/demo", "/api/users", 20);

    expect(result).toHaveLength(1);
    expect(result[0]).toMatchObject({
      key: "spring-endpoint:users",
      filePath: "C:/work/demo/src/main/java/UserController.java",
      line: 12,
      column: 3,
    });
  });

  test("keeps route ranking and the requested result limit", () => {
    const result = toQuickOpenEndpointResults(endpoints, "C:/work/demo", "api", 1);
    expect(result.map((item) => item.endpoint.id)).toEqual(["orders"]);
  });

  test("returns no results for blank queries", () => {
    expect(toQuickOpenEndpointResults(endpoints, "C:/work/demo", "   ", 20)).toEqual([]);
  });
});
