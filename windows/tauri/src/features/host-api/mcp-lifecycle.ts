import type { hostControl, IdeCapabilities, IdePermissions, IdeRequest } from "./ide-capabilities";

type Capability = Pick<IdeCapabilities, "permissions" | "revoke" | "isCurrent" | "call">;
export interface McpRequestError {
  key: "settings.mcp.error.expired" | "settings.mcp.error.undelivered" | "settings.mcp.error.request" | "settings.mcp.error.transport";
  detail?: string;
}
export interface McpConnection {
  hostID: string;
  configuration: string;
  api: Capability;
  closed: boolean;
  status: "waiting" | "active" | "failed";
  error: McpRequestError | null;
}
export interface McpConnectionState {
  connections: Record<string, McpConnection>;
  error: string | null;
}
interface Dependencies {
  createAPI(workspaceID: string, root: string, permissions: IdePermissions): Capability;
  paths(): Promise<{ directory: string; helperPath: string }>;
  control: typeof hostControl;
  now(): number;
  open(
    args: Record<string, unknown>,
    receive: (event: { hostID: string; requestID: string }) => Promise<void>,
  ): Promise<{
    hostID: string;
    configuration: unknown;
    dispose(): void | Promise<void>;
  }>;
}
interface Grant {
  api: Capability;
  connection?: McpConnection;
  ready: Promise<void>;
  dispose?: () => void | Promise<void>;
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
      if (grant.connection) connections[id] = { ...grant.connection };
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

  private async dispose(grant: Grant) {
    const dispose = grant.dispose;
    grant.dispose = undefined;
    try {
      await dispose?.();
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
    }
    this.publish();
    if (grant.connection) {
      await this.close(grant.connection.hostID);
      await this.dispose(grant);
    }
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
      const receive = async (event: { hostID: string; requestID: string }) => {
        // Native delivery can precede the open IPC result. Wait for publication,
        // then bind to this grant; never route late events to its replacement.
        await grant.ready;
        const connection = grant.connection;
        if (!current() || !connection || event.hostID !== connection.hostID) return;
        if (!grant.api.isCurrent()) {
          await this.disable(workspaceID);
          return;
        }
        try {
          // Measure from before IPC, conservatively including outbound delivery time.
          // A claimed reply may itself sit in a suspended WebView's queue.
          const started = this.dependencies.now();
          const { request } = await this.dependencies.control<{
            request: (IdeRequest & { remainingMilliseconds: number }) | null;
          }>("claim", event);
          if (!current() || !grant.api.isCurrent() || !request) return;
          let result: unknown;
          const canStart = () => {
            const elapsed = this.dependencies.now() - started;
            return (
              Number.isFinite(request.remainingMilliseconds) &&
              elapsed >= 0 &&
              elapsed < request.remainingMilliseconds
            );
          };
          try {
            if (!canStart()) {
              result = {
                error: {
                  code: "TIMEOUT",
                  message:
                    "The request expired before execution. Inspect operations before retrying.",
                },
              };
            } else {
              result = await grant.api.call(request.name, request.arguments, canStart);
            }
          } catch (error) {
            result = { error: { code: "OPERATION_FAILED", message: String(error) } };
          }
          if (!current()) return;
          const { delivered } = await this.dependencies.control<{ delivered: boolean }>("respond", {
            hostID: connection.hostID,
            requestID: request.requestID,
            result,
          });
          if (!current()) return;
          const failure = (result as { error?: { code?: string } } | null)?.error;
          connection.status = delivered && !failure ? "active" : "failed";
          // Protocol diagnostics stay unchanged for the caller. Product-owned
          // UI errors are translated at render time, including language changes.
          connection.error = failure?.code === "TIMEOUT"
            ? { key: "settings.mcp.error.expired" }
            : !delivered
              ? { key: "settings.mcp.error.undelivered" }
              : failure ? { key: "settings.mcp.error.request" } : null;
          this.publish();
        } catch (error) {
          if (!current()) return;
          // Delivery failure is not authorization revocation. A later request can
          // succeed through the same event subscription; ambiguous mutations are never replayed.
          connection.status = "failed";
          connection.error = { key: "settings.mcp.error.transport", detail: String(error) };
          this.publish();
        }
      };
      const result = await this.dependencies.open(
        { ...paths, workspaceKey: root, permissions },
        receive,
      );
      grant.dispose = result.dispose;
      if (!current() || !grant.api.isCurrent()) {
        await this.close(result.hostID);
        await this.dispose(grant);
        if (current()) throw new Error("The selected project was closed");
        return;
      }
      const connection: McpConnection = {
        hostID: result.hostID,
        configuration: JSON.stringify(result.configuration, null, 2),
        api: grant.api,
        closed: false,
        status: "waiting",
        error: null,
      };
      grant.connection = connection;
      this.publish();
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
