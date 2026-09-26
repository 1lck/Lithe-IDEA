/** Data-only run plans. The host launches them only after an explicit user action. */
export interface ExtensionRunPlan {
  id: string;
  name: string;
  description?: string;
  sourceLabel: string;
  executable: string;
  arguments: string[];
}

export interface RunActionExtensionAPI {
  runActions: {
    register(provider: (manifests: Record<string, string>) => ExtensionRunPlan[]): {
      dispose(): void;
    };
  };
}
