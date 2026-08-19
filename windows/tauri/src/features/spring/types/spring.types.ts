export interface SpringProperty {
  name: string;
  typeName?: string | null;
  description?: string | null;
  defaultValue?: string | null;
  sourcePath?: string | null;
  sourceLine?: number | null;
  sourceColumn?: number | null;
}

export interface SpringConfigurationValue {
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
}

export interface SpringPropertyReference {
  key: string;
  path: string;
  line: number;
  column: number;
}

export interface SpringBean {
  id: string;
  name: string;
  typeName: string;
  path: string;
  line: number;
  column: number;
  kind: string;
}

export interface SpringInjection {
  path: string;
  line: number;
  column: number;
  typeName: string;
  qualifier?: string | null;
  beanIds: string[];
}

export interface SpringIndex {
  properties: SpringProperty[];
  values: SpringConfigurationValue[];
  propertyReferences: SpringPropertyReference[];
  beans: SpringBean[];
  injections: SpringInjection[];
}

export interface SpringNavigationLocation {
  filePath: string;
  line: number;
  column: number;
  symbol: string;
}

export const EMPTY_SPRING_INDEX: SpringIndex = {
  properties: [],
  values: [],
  propertyReferences: [],
  beans: [],
  injections: [],
};
