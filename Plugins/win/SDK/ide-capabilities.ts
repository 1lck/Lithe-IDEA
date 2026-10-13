/** Project-bound IDE API v1. Requires permissions.ide and an enabled project grant. */
export interface IdeCapabilityExtensionAPI {
  ide: {
    authorizedWorkspaceIDs(): Promise<string[]>;
    call(workspaceID: string, name: string, args: Record<string, unknown>): Promise<unknown>;
  };
}
