import type { hostControl, IdeCapabilities, IdePermissions, IdeRequest } from "./ide-capabilities";

type Capability = Pick<IdeCapabilities, "permissions" | "revoke" | "isCurrent" | "call">;
export interface McpConnection {
  hostID: string;
  configuration: string;
  api: Capability;
  closed: boolean;
  timer?: ReturnType<typeof setTimeout>;
}
export interface McpConnectionState {
  connections: Record<string, McpConnection>;
  error: string | null;
}
interface Dependencies {
  createAPI(workspaceID: string, root: string, permissions: IdePermissions): Capability;
  paths(): Promise<{ directory: string; helperPath: string }>;
  control: typeof hostControl;
  schedule(callback: () => void): ReturnType<typeof setTimeout>;
  cancel(timer: ReturnType<typeof setTimeout> | undefined): void;
}
interface Grant {
  api: Capability;
  connection?: McpConnection;
  ready: Promise<void>;
}

/** Own pending opens as well as published connections so revocation cannot be undone by late IO. */
export class McpConnectionManager {
  private grants = new Map<string, Grant>();
  private error: string | null = null;

  constructor(
    private dependencies: Dependencies,
    private changed: (state: McpConnectionState) => void,
  ) {}

  private publish() {
    const connections: Record<string, McpConnection> = {};
    for (const [id, grant] of this.grants) {
      if (grant.connection) connections[id] = grant.connection;
    }
    this.changed({ connections, error: this.error });
  }

  private async close(hostID: string) {
    try {
      await this.dependencies.control("close", { hostID });
    } catch (error) {
      this.error = String(error);
      this.publish();
    }
  }

  async disable(workspaceID: string) {
    const grant = this.grants.get(workspaceID);
    if (!grant) return;
    this.grants.delete(workspaceID);
    grant.api.revoke();
    if (grant.connection) {
      grant.connection.closed = true;
      this.dependencies.cancel(grant.connection.timer);
    }
    this.publish();
    if (grant.connection) await this.close(grant.connection.hostID);
    // An open already in flight closes its own late native host before resolving.
    await grant.ready;
  }

  enable(workspaceID: string, root: string, permissions: IdePermissions) {
    const previous = this.disable(workspaceID);
    const grant: Grant = {
      api: this.dependencies.createAPI(workspaceID, root, { ...permissions }),
      ready: Promise.resolve(),
    };
    this.grants.set(workspaceID, grant);
    this.error = null;
    this.publish();
    grant.ready = this.open(workspaceID, root, permissions, grant, previous);
    return grant.ready;
  }

  private async open(
    workspaceID: string,
    root: string,
    permissions: IdePermissions,
    grant: Grant,
    previous: Promise<void>,
  ) {
    const current = () => this.grants.get(workspaceID) === grant;
    try {
      await previous;
      if (!current()) return;
      const paths = await this.dependencies.paths();
      if (!current()) return;
      if (!grant.api.isCurrent()) throw new Error("The selected project was closed");
      const result = await this.dependencies.control<{ hostID: string; configuration: unknown }>(
        "open",
        { ...paths, workspaceKey: root, permissions },
      );
      if (!current() || !grant.api.isCurrent()) {
        await this.close(result.hostID);
        if (current()) throw new Error("The selected project was closed");
        return;
      }
      const connection: McpConnection = {
        hostID: result.hostID,
        configuration: JSON.stringify(result.configuration, null, 2),
        api: grant.api,
        closed: false,
      };
      grant.connection = connection;
      this.publish();
      const respond = async (request: IdeRequest) => {
        let result: unknown;
        try {
          result = await grant.api.call(request.name, request.arguments);
        } catch (error) {
          result = { error: { code: "OPERATION_FAILED", message: String(error) } };
        }
        if (!current()) return;
        try {
          await this.dependencies.control("respond", {
            hostID: connection.hostID,
            requestID: request.requestID,
            result,
          });
        } catch (error) {
          if (current()) {
            this.error = String(error);
            this.publish();
          }
        }
      };
      const poll = async () => {
        if (!current()) return;
        if (!grant.api.isCurrent()) {
          await this.disable(workspaceID);
          return;
        }
        try {
          const result = await this.dependencies.control<{ requests: IdeRequest[] }>("poll", {
            hostID: connection.hostID,
          });
          if (current()) for (const request of result.requests) void respond(request);
        } catch (error) {
          // A response from the previous grant must never close a replacement connection.
          if (current()) {
            this.error = String(error);
            await this.disable(workspaceID);
          }
          return;
        }
        if (current()) connection.timer = this.dependencies.schedule(() => void poll());
      };
      void poll();
    } catch (error) {
      if (current()) {
        this.grants.delete(workspaceID);
        grant.api.revoke();
        this.error = String(error);
        this.publish();
      }
    }
  }

  async closeAll() {
    await Promise.all([...this.grants.keys()].map((id) => this.disable(id)));
  }
}
