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
