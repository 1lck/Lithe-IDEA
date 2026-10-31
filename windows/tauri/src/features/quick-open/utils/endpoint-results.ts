import type { SpringEndpoint } from "@/features/spring/types/spring.types";
import { searchSpringEndpoints } from "@/features/spring/utils/spring-endpoint-filter";
import { resolveSpringEndpointLocation } from "@/features/spring/utils/spring-navigation";

export interface QuickOpenEndpointResult {
  key: string;
  endpoint: SpringEndpoint;
  filePath: string;
  /** One-based coordinates expected by the file-system navigation action. */
  line: number;
  column: number;
}

export function toQuickOpenEndpointResults(
  endpoints: readonly SpringEndpoint[],
  root: string,
  query: string,
  limit: number,
): QuickOpenEndpointResult[] {
  return searchSpringEndpoints(endpoints, query, limit).flatMap((endpoint) => {
    const location = resolveSpringEndpointLocation(endpoint, root);
    if (!location) return [];
    return [
      {
        key: `spring-endpoint:${endpoint.id}`,
        endpoint,
        filePath: location.filePath,
        line: location.line + 1,
        column: location.column + 1,
      },
    ];
  });
}
