export interface MybatisStatement {
  id: string;
  namespace: string;
  statementId: string;
  kind: string;
  javaPath: string;
  javaLine: number;
  javaColumn: number;
  javaEndLine: number;
  xmlPath: string;
  xmlLine: number;
  xmlColumn: number;
}

export interface MybatisIndex {
  statements: MybatisStatement[];
}

export interface MybatisNavigationLocation {
  filePath: string;
  line: number;
  column: number;
  symbol: string;
}

export const EMPTY_MYBATIS_INDEX: MybatisIndex = {
  statements: [],
};
