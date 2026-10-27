import type { SpringEndpoint } from "../types/spring.types";

export function filterSpringEndpoints(
  endpoints: readonly SpringEndpoint[],
  query: string,
): SpringEndpoint[] {
  const value = query.trim().toLowerCase();
  if (!value) return [...endpoints];
  return endpoints.filter((endpoint) => {
    const searchableFields = [
      endpoint.route,
      endpoint.controller,
      endpoint.method,
      endpoint.httpMethods.join(" "),
    ];
    return searchableFields.some((field) => field.toLowerCase().includes(value));
  });
}

function matchScore(field: string, query: string, exact: number, prefix: number, includes: number) {
  const value = field.toLowerCase();
  if (value === query) return exact;
  if (value.startsWith(query)) return prefix;
  if (value.includes(query)) return includes;
  return 0;
}

function endpointSearchScore(endpoint: SpringEndpoint, query: string): number {
  const route = endpoint.route.toLowerCase();
  const combined = `${endpoint.httpMethods.join(" ").toLowerCase()} ${route}`;
  return Math.max(
    matchScore(route, query, 1000, 900, 800),
    matchScore(combined, query, 750, 700, 650),
    matchScore(endpoint.controller, query, 600, 550, 500),
    matchScore(endpoint.method, query, 450, 400, 350),
  );
}

/** Search endpoints for a typed route, controller, method, or HTTP verb. */
export function searchSpringEndpoints(
  endpoints: readonly SpringEndpoint[],
  query: string,
  limit: number,
): SpringEndpoint[] {
  const value = query.trim().toLowerCase();
  if (!value || limit <= 0) return [];

  return endpoints
    .map((endpoint) => ({ endpoint, score: endpointSearchScore(endpoint, value) }))
    .filter(({ score }) => score > 0)
    .sort(
      (left, right) =>
        right.score - left.score ||
        left.endpoint.route.localeCompare(right.endpoint.route) ||
        left.endpoint.httpMethods.join(",").localeCompare(right.endpoint.httpMethods.join(",")),
    )
    .slice(0, limit)
    .map(({ endpoint }) => endpoint);
}
