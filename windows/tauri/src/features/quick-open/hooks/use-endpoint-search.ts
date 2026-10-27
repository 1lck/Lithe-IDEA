import { useMemo } from "react";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { useSpringStore } from "@/features/spring/stores/spring.store";
import { isSameSpringRoot } from "@/features/spring/utils/spring-root";
import { MAX_ENDPOINT_RESULTS } from "../constants/limits";
import { toQuickOpenEndpointResults } from "../utils/endpoint-results";

export const useEndpointSearch = (query: string, isActive: boolean) => {
  const endpoints = useSpringStore.use.index().endpoints;
  const loadedRoot = useSpringStore.use.loadedRoot();
  const rootFolderPath = useFileSystemStore((state) => state.rootFolderPath);

  return useMemo(() => {
    if (!isActive || !rootFolderPath || !isSameSpringRoot(loadedRoot, rootFolderPath)) return [];
    return toQuickOpenEndpointResults(endpoints, rootFolderPath, query, MAX_ENDPOINT_RESULTS);
  }, [endpoints, isActive, loadedRoot, query, rootFolderPath]);
};
