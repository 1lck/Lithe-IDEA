import { executeCore, type CoreResponse } from "@/core/lithe-core-client";
import { EMPTY_MYBATIS_INDEX, type MybatisIndex } from "../types/mybatis.types";

interface CoreMybatisIndex {
  statements?: MybatisIndex["statements"];
}

function coreData<T>(response: CoreResponse<T>): T {
  if (response.ok) return response.data;
  throw new Error(`${response.error.code}: ${response.error.message}`);
}

export async function requestMybatisIndex(args: {
  root: string;
  paths: string[];
  textOverrides?: Record<string, string>;
}): Promise<MybatisIndex> {
  if (args.paths.length === 0) return EMPTY_MYBATIS_INDEX;
  const response = await executeCore<CoreMybatisIndex>({
    id: crypto.randomUUID(),
    timeoutMilliseconds: 30_000,
    command: "mybatis.index",
    payload: {
      root: args.root,
      paths: args.paths,
      textOverrides: args.textOverrides ?? {},
    },
  });
  const data = coreData(response);
  return {
    statements: data.statements ?? [],
  };
}
