import { executeCore, type CoreResponse } from "@/core/lithe-core-client";
import type { SpringIndex } from "../types/spring.types";

interface CoreSpringIndex {
  properties: Array<{
    name: string;
    typeName?: string | null;
    description?: string | null;
    defaultValue?: string | null;
    sourcePath?: string | null;
    sourceLine?: number | null;
    sourceColumn?: number | null;
  }>;
  values: Array<{
    key: string;
    value: string;
    path: string;
    line: number;
    column: number;
    profile?: string | null;
    overridesBaseValue: boolean;
    targetPath?: string | null;
    targetLine?: number | null;
    targetColumn?: number | null;
  }>;
  propertyReferences: Array<{
    key: string;
    path: string;
    line: number;
    column: number;
  }>;
  beans: Array<{
    id: string;
    name: string;
    typeName: string;
    path: string;
    line: number;
    column: number;
    kind: string;
  }>;
  injections: Array<{
    path: string;
    line: number;
    column: number;
    typeName: string;
    qualifier?: string | null;
    beanIds: string[];
  }>;
}

function coreData<T>(response: CoreResponse<T>): T {
  if (response.ok) return response.data;
  throw new Error(`${response.error.code}: ${response.error.message}`);
}

export async function requestSpringIndex(args: {
  root: string;
  paths: string[];
  metadataRepositories?: string[];
  textOverrides?: Record<string, string>;
  refreshDependencyMetadata: boolean;
}): Promise<SpringIndex> {
  const response = await executeCore<CoreSpringIndex>({
    id: crypto.randomUUID(),
    timeoutMilliseconds: args.refreshDependencyMetadata ? 60_000 : 30_000,
    command: "spring.index",
    payload: {
      root: args.root,
      paths: args.paths,
      metadataRepositories: args.metadataRepositories ?? [],
      textOverrides: args.textOverrides ?? {},
      refreshDependencyMetadata: args.refreshDependencyMetadata,
    },
  });
  const data = coreData(response);
  return {
    properties: data.properties ?? [],
    values: data.values ?? [],
    propertyReferences: data.propertyReferences ?? [],
    beans: data.beans ?? [],
    injections: data.injections ?? [],
  };
}
