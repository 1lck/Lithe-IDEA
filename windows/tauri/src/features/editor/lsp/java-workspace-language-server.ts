import { LspOperationLog } from "@/platform/lsp-session-lifecycle";
import type { WorkspaceLaunchScope } from "@/features/workspace/types/workspace-launch-scope";
import { JAVA_LANGUAGE_ID } from "./built-in-language-support";
import {
  clearLanguageServerReadyFeedback,
  showLanguageServerFailure,
  showLanguageServerPreparing,
  showLanguageServerReady,
  type LanguageServerFailureFeedback,
} from "./language-server-feedback";
import {
  LspClient,
  type LspWorkspaceStartOutcome,
} from "./lsp-client";

interface WorkspaceLanguageServerClient {
  start(
    scope: WorkspaceLaunchScope,
    representativeFilePath?: string,
  ): Promise<LspWorkspaceStartOutcome>;
  stop(workspacePath: string): Promise<void>;
}

interface OperationLog {
  succeeded(details?: Record<string, unknown>): void;
  failed(reason: unknown, details?: Record<string, unknown>): void;
  cancelled(reason: string, details?: Record<string, unknown>): void;
  timedOut(details?: Record<string, unknown>): void;
}

type OperationLogFactory = (
  name: string,
  operationId: string,
  context: Record<string, unknown>,
) => OperationLog;

type JavaWorkspacePreparationOutcome =
  | { kind: "ready" }
  | { kind: "cancelled"; reason: "superseded-owner" | "workspace-closed-before-ready" }
  | { kind: "unavailable"; reason: "unsupportedHost" | "notConfigured" }
  | { kind: "failed"; error: unknown }
  | { kind: "timedOut"; error: unknown };

type WorkspaceOwnerState =
  | { phase: "created" }
  | { phase: "starting"; task: Promise<JavaWorkspacePreparationOutcome> }
  | { phase: "ready"; task: Promise<JavaWorkspacePreparationOutcome> }
  | { phase: "stopping"; startTask: Promise<JavaWorkspacePreparationOutcome>; task: Promise<void> }
  | { phase: "stopFailed"; startTask: Promise<JavaWorkspacePreparationOutcome> };

interface WorkspaceOwner {
  operationId: string;
  operation: OperationLog;
  scope: WorkspaceLaunchScope;
  representativeJavaFile: string;
  state: WorkspaceOwnerState;
}

function workspaceKey(scope: WorkspaceLaunchScope): string {
  return `${scope.workspaceId}\0${scope.root.replace(/\\/g, "/").toLowerCase()}`;
}

function isTimeout(error: unknown): boolean {
  const code = (error as { code?: unknown } | null)?.code;
  return code === "timed_out" || code === "initializeTimeout" || code === "serviceReadyTimeout";
}

export class JavaWorkspaceLanguageServerOwner {
  private readonly owners = new Map<string, WorkspaceOwner>();

  constructor(
    private readonly client: WorkspaceLanguageServerClient,
    private readonly createOperationLog: OperationLogFactory = (name, operationId, context) =>
      new LspOperationLog(name, operationId, context),
    private readonly notifyReady: (
      workspacePath: string,
      languageId: string,
    ) => void = showLanguageServerReady,
    private readonly clearReady: (
      workspacePath: string,
      languageId?: string,
    ) => void = clearLanguageServerReadyFeedback,
    private readonly notifyPreparing: (
      workspacePath: string,
      languageId: string,
    ) => void = showLanguageServerPreparing,
    private readonly notifyFailure: (
      workspacePath: string,
      languageId: string,
      failure: LanguageServerFailureFeedback,
      retry: () => void,
    ) => void = showLanguageServerFailure,
  ) {}

  prewarm(
    scope: WorkspaceLaunchScope,
    representativeJavaFile: string,
  ): Promise<JavaWorkspacePreparationOutcome> {
    const workspacePath = scope.root;
    const key = workspaceKey(scope);
    const existing = this.owners.get(key);
    if (existing) {
      if (existing.state.phase === "starting" || existing.state.phase === "ready") {
        return existing.state.task;
      }
      if (existing.state.phase === "stopping") {
        return existing.state.task.then(() => this.prewarm(scope, representativeJavaFile));
      }
      if (existing.state.phase === "stopFailed") {
        return this.stop(scope).then(() =>
          this.prewarm(scope, representativeJavaFile),
        );
      }
      this.owners.delete(key);
    }

    const operationId = crypto.randomUUID();
    const operation = this.createOperationLog("workspacePrewarm", operationId, {
      workspaceId: scope.workspaceId,
      workspacePath,
      languageId: JAVA_LANGUAGE_ID,
    });
    this.notifyPreparing(workspacePath, JAVA_LANGUAGE_ID);
    const owner: WorkspaceOwner = {
      operationId,
      operation,
      scope,
      representativeJavaFile,
      state: { phase: "created" },
    };
    const task = this.start(owner, key);
    owner.state = { phase: "starting", task };
    this.owners.set(key, owner);
    return task;
  }

  private async start(
    owner: WorkspaceOwner,
    key: string,
  ): Promise<JavaWorkspacePreparationOutcome> {
    const { scope, representativeJavaFile, operation } = owner;
    const workspacePath = scope.root;
    try {
      const startOutcome = await this.client.start(scope, representativeJavaFile);
      if (this.owners.get(key) !== owner) {
        operation.cancelled("superseded-owner");
        return { kind: "cancelled", reason: "superseded-owner" };
      }
      if (owner.state.phase === "stopping") {
        operation.cancelled("workspace-closed-before-ready");
        return { kind: "cancelled", reason: "workspace-closed-before-ready" };
      }
      if (startOutcome.kind !== "ready") {
        operation.failed({ code: "runtime_missing", reason: startOutcome.kind });
        this.notifyFailure(
          workspacePath,
          JAVA_LANGUAGE_ID,
          { kind: "unavailable" },
          () => void this.prewarm(scope, representativeJavaFile),
        );
        if (this.owners.get(key) === owner) this.owners.delete(key);
        return { kind: "unavailable", reason: startOutcome.kind };
      }

      const readyTask =
        owner.state.phase === "starting"
          ? owner.state.task
          : Promise.resolve({ kind: "ready" } as const);
      owner.state = { phase: "ready", task: readyTask };
      operation.succeeded();
      this.notifyReady(workspacePath, JAVA_LANGUAGE_ID);
      return { kind: "ready" };
    } catch (error) {
      if (this.owners.get(key) === owner && owner.state.phase === "stopping") {
        operation.cancelled("workspace-closed-before-ready", {
          startError: error instanceof Error ? error.message : String(error),
        });
        return { kind: "cancelled", reason: "workspace-closed-before-ready" };
      }

      const timedOut = isTimeout(error);
      if (timedOut) operation.timedOut();
      else operation.failed(error);
      this.notifyFailure(
        workspacePath,
        JAVA_LANGUAGE_ID,
        {
          kind: timedOut ? "timedOut" : "failed",
          detail: error instanceof Error ? error.message : String(error),
        },
        () => void this.prewarm(scope, representativeJavaFile),
      );
      if (this.owners.get(key) === owner) this.owners.delete(key);
      return timedOut ? { kind: "timedOut", error } : { kind: "failed", error };
    }
  }

  async stop(scope: WorkspaceLaunchScope): Promise<void> {
    const workspacePath = scope.root;
    const key = workspaceKey(scope);
    const owner = this.owners.get(key);
    if (owner?.state.phase === "stopping") return owner.state.task;

    const operationId = crypto.randomUUID();
    const operation = this.createOperationLog("workspaceStop", operationId, {
      workspaceId: scope.workspaceId,
      workspacePath,
      languageId: JAVA_LANGUAGE_ID,
    });
    if (!owner) {
      try {
        await this.client.stop(workspacePath);
        operation.succeeded();
      } catch (reason) {
        operation.failed(reason);
        throw reason;
      } finally {
        this.clearReady(workspacePath, JAVA_LANGUAGE_ID);
      }
      return;
    }

    const startTask =
      owner.state.phase === "starting" || owner.state.phase === "ready"
        ? owner.state.task
        : owner.state.phase === "stopFailed"
          ? owner.state.startTask
          : Promise.resolve({ kind: "cancelled", reason: "superseded-owner" } as const);
    const stopTask = (async () => {
      try {
        await startTask.catch(() => ({ kind: "cancelled", reason: "start-failed" }) as const);
        await this.client.stop(workspacePath);
        operation.succeeded();
        if (this.owners.get(key) === owner) this.owners.delete(key);
      } catch (reason) {
        operation.failed(reason);
        if (this.owners.get(key) === owner) {
          owner.state = { phase: "stopFailed", startTask };
        }
        throw reason;
      } finally {
        this.clearReady(workspacePath, JAVA_LANGUAGE_ID);
      }
    })();
    owner.state = { phase: "stopping", startTask, task: stopTask };
    return stopTask;
  }
}

let sharedOwner: JavaWorkspaceLanguageServerOwner | undefined;

export function getJavaWorkspaceLanguageServerOwner(): JavaWorkspaceLanguageServerOwner {
  sharedOwner ??= new JavaWorkspaceLanguageServerOwner(LspClient.getInstance());
  return sharedOwner;
}
