/**
 * One agent's connection and conversations inside a project.
 *
 * This is the Windows counterpart of `AgentConnectionModel.swift`: the same
 * event names, the same command tokens, and the same rules about when a
 * conversation may be prompted. Keeping the reduction here means the Tauri
 * command layer stays a byte pipe and both products behave identically.
 *
 * It is framework-free on purpose: the panel subscribes through
 * `getSnapshot`/`subscribe`, and tests drive it with a scripted transport.
 */

import {
  addFileReferences,
  appendMessage,
  createConversation,
  currentPermission,
  enqueuePermission,
  finishActiveTurn,
  interruptPendingTools,
  parseContextUsage,
  parseSessionConfigOptions,
  parseSubscriptionQuota,
  permissionPrompt,
  promptDisplayText,
  provisionalTitle,
  stopReasonMessage,
  updateText,
  upsertToolMessage,
  type AgentConnectionState,
  type AgentConversation,
  type AgentConversationMessage,
  type AgentPrompt,
  type AgentSessionSummary,
  type AgentSubscriptionQuota,
} from "../types/agent.types";
import { parseTurnUsage, startTurn } from "../types/agent-turn-statistics";
import type {
  AgentLaunchConfiguration,
  AgentTransport,
  AgentTransportConnection,
} from "../services/agent-transport";

/** Coalesces streamed chunks so one turn does not re-render per token. */
export interface AgentFlushScheduler {
  schedule(callback: () => void): void;
  cancel(): void;
}

function defaultScheduler(): AgentFlushScheduler {
  let handle: number | null = null;
  const request = typeof requestAnimationFrame === "function"
    ? requestAnimationFrame
    : (callback: FrameRequestCallback) => setTimeout(() => callback(Date.now()), 0) as unknown as number;
  const cancel = typeof cancelAnimationFrame === "function"
    ? cancelAnimationFrame
    : (id: number) => clearTimeout(id);
  return {
    schedule(callback) {
      if (handle !== null) return;
      handle = request(() => {
        handle = null;
        callback();
      });
    },
    cancel() {
      if (handle === null) return;
      cancel(handle);
      handle = null;
    },
  };
}

export class AgentConnectionBusyError extends Error {}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function asString(value: unknown): string | null {
  return typeof value === "string" ? value : null;
}

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

export interface AgentConnectionSnapshot {
  connectionState: AgentConnectionState;
  usesSubscription: boolean;
  subscriptionEmail: string | null;
  subscriptionPlan: string | null;
  subscriptionQuota: AgentSubscriptionQuota | null;
  quotaFailure: string | null;
  agentName: string | null;
  agentVersion: string | null;
  sessions: AgentSessionSummary[];
  selectedSessionID: string | null;
  conversations: Record<string, AgentConversation>;
  openSessionIDs: string[];
  pendingNewConversationPrompt: string | null;
  /** Monotonic submission time of that prompt, so its wait is timed too. */
  pendingNewConversationStartedAt: number | null;
  canLoadSessions: boolean;
  isRefreshingSessions: boolean;
  historyError: string | null;
  errorMessage: string | null;
  isCreatingSession: boolean;
}

/** A connection that has not started yet. */
function emptySnapshot(): AgentConnectionSnapshot {
  return {
    connectionState: { status: "idle" },
    usesSubscription: false,
    subscriptionEmail: null,
    subscriptionPlan: null,
    subscriptionQuota: null,
    quotaFailure: null,
    agentName: null,
    agentVersion: null,
    sessions: [],
    selectedSessionID: null,
    conversations: {},
    openSessionIDs: [],
    pendingNewConversationPrompt: null,
    pendingNewConversationStartedAt: null,
    canLoadSessions: false,
    isRefreshingSessions: false,
    historyError: null,
    errorMessage: null,
    isCreatingSession: false,
  };
}

export class AgentConnectionModel {
  private readonly transport: AgentTransport;
  private readonly scheduler: AgentFlushScheduler;
  private readonly listeners = new Set<() => void>();

  private connection: AgentTransportConnection | null = null;
  private closePromise: Promise<void> | null = null;
  private canListSessions = false;
  private nextToken = 0;
  /** Prompts waiting for a session: keyed by new-session token or session id. */
  private queuedPrompts = new Map<string, AgentPrompt>();
  private loadTokens = new Map<string, string>();
  private pendingText = new Map<string, string>();
  private createToken: string | null = null;
  private loadBackups = new Map<string, AgentConversation>();
  /** Export loads must not add a tab the user never asked for. */
  private quietLoadTokens = new Set<string>();
  /** Export resolvers, keyed by the load token they are waiting for. */
  private transcriptWaiters = new Map<
    string,
    (messages: AgentConversationMessage[] | null) => void
  >();
  /** One replay at a time: the host orders loads per connection, not per call. */
  private transcriptChain: Promise<unknown> = Promise.resolve();
  /** Replays in flight or queued, so the first one starts immediately. */
  private transcriptPending = 0;
  /**
   * Sessions prepared locally without a submitted prompt. Codex does not
   * persist their rollout until the first prompt, so they cannot be resumed.
   */
  private unpromptedSessionIDs = new Set<string>();
  private historyRefreshToken: string | null = null;
  private stale = false;
  private snapshot: AgentConnectionSnapshot;

  /** Monotonic milliseconds; injected so turn timing is deterministic in tests. */
  readonly now: () => number;

  constructor(
    transport: AgentTransport,
    scheduler: AgentFlushScheduler = defaultScheduler(),
    now: () => number = () => performance.now(),
  ) {
    this.transport = transport;
    this.scheduler = scheduler;
    this.now = now;
    this.snapshot = emptySnapshot();
  }

  /**
   * Forget every session and conversation. The window owns one project, so a
   * project switch keeps the model identity the panel subscribes to.
   */
  reset(): void {
    if (this.connection !== null) {
      throw new AgentConnectionBusyError("Close the Agent connection before resetting it.");
    }
    this.scheduler.cancel();
    this.canListSessions = false;
    this.queuedPrompts.clear();
    this.loadTokens.clear();
    this.failTranscripts();
    this.pendingText.clear();
    this.createToken = null;
    this.loadBackups.clear();
    this.unpromptedSessionIDs.clear();
    this.historyRefreshToken = null;
    this.stale = false;
    this.update(emptySnapshot());
  }

  getSnapshot = (): AgentConnectionSnapshot => this.snapshot;

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };

  get hasActiveConnection(): boolean {
    return this.connection !== null;
  }

  get selectedConversation(): AgentConversation | null {
    const id = this.snapshot.selectedSessionID;
    return id === null ? null : (this.snapshot.conversations[id] ?? null);
  }

  private update(change: Partial<AgentConnectionSnapshot>): void {
    this.snapshot = { ...this.snapshot, ...change };
    for (const listener of this.listeners) listener();
  }

  private setConversation(sessionID: string, conversation: AgentConversation): void {
    this.update({ conversations: { ...this.snapshot.conversations, [sessionID]: conversation } });
  }

  /** Mutate one conversation, creating it when the agent reports it first. */
  private editConversation(
    sessionID: string,
    edit: (conversation: AgentConversation) => AgentConversation,
  ): void {
    this.setConversation(sessionID, edit(this.snapshot.conversations[sessionID] ?? createConversation()));
  }

  private makeToken(): string {
    return `t${++this.nextToken}`;
  }
  // MARK: Connection

  /** Start the agent for this project. A second call while connected is a no-op. */
  async connect(configuration: AgentLaunchConfiguration): Promise<void> {
    if (this.connection !== null) return;
    if (this.closePromise !== null) {
      throw new AgentConnectionBusyError("The Agent session is still stopping.");
    }
    this.stale = false;
    const connectionID = crypto.randomUUID();
    this.update({
      errorMessage: null,
      usesSubscription: configuration.authentication === "codexSubscription",
      subscriptionEmail: null,
      subscriptionPlan: null,
      subscriptionQuota: null,
      quotaFailure: null,
      connectionState: { status: "connecting" },
    });
    let connection: AgentTransportConnection;
    try {
      connection = await this.transport.open(connectionID, configuration, (event) => {
        if (!this.stale) this.receive(event);
      });
    } catch (error) {
      this.update({ connectionState: { status: "failed", message: messageOf(error) } });
      throw error;
    }
    // A stop that landed while `open` was resolving owns the teardown.
    if (this.stale) {
      await connection.close().catch(() => undefined);
      return;
    }
    this.connection = connection;
  }

  /** Show why the agent could not start, e.g. incomplete settings. */
  reportConnectionFailure(message: string): void {
    if (this.connection !== null) return;
    this.update({ connectionState: { status: "failed", message } });
  }

  /** Stop the agent and wait for its process tree to exit. */
  async stop(): Promise<void> {
    const previous = this.closePromise;
    const old = this.detachConnection(null);
    await old?.close().catch(() => undefined);
    await previous?.catch(() => undefined);
  }

  authenticate(): void {
    if (!this.snapshot.usesSubscription) return;
    if (this.snapshot.connectionState.status !== "authenticationRequired") return;
    if (this.sendCommand({ kind: "authenticate" })) {
      this.update({ connectionState: { status: "authenticating" } });
    }
  }

  /** Keep a cancelled sign-in out of the idle view, which reconnects on appear. */
  async cancelAuthentication(): Promise<void> {
    if (this.snapshot.connectionState.status !== "authenticating") return;
    const old = this.detachConnection({
      status: "failed",
      message: "ChatGPT sign-in was cancelled.",
    });
    if (old === null) return;
    const closing = old.close().catch(() => undefined);
    this.closePromise = closing;
    await closing;
    if (this.closePromise === closing) this.closePromise = null;
  }

  /** The host coalesces quota requests, so the panel may ask on every tick. */
  refreshQuota(): void {
    if (!this.snapshot.usesSubscription) return;
    if (this.snapshot.connectionState.status !== "ready") return;
    this.sendCommand({ kind: "refreshQuota" });
  }

  get canRefreshSessions(): boolean {
    return this.canListSessions && this.snapshot.connectionState.status === "ready";
  }

  refreshSessions(): void {
    if (!this.canRefreshSessions || this.snapshot.isRefreshingSessions) return;
    const token = this.makeToken();
    this.historyRefreshToken = token;
    this.update({ isRefreshingSessions: true, historyError: null });
    if (!this.sendCommand({ kind: "listSessions", token })) {
      this.historyRefreshToken = null;
      this.update({ isRefreshingSessions: false, historyError: this.snapshot.errorMessage });
    }
  }

  /**
   * True when this session's transcript can be replayed for an export.
   *
   * A session already loaded from this run has a complete snapshot; anything
   * else needs a live connection that can list and load sessions.
   */
  canExportTranscript(sessionID: string): boolean {
    if (this.snapshot.conversations[sessionID]?.hasCompleteHistory === true) return true;
    return this.snapshot.canLoadSessions && this.snapshot.connectionState.status === "ready";
  }

  /**
   * Replay one session for an export, without changing the active tab.
   *
   * Returns `null` when the transcript cannot be trusted: a partially replayed
   * session, a failed load, or a connection that went away. Loads stay
   * sequential so two replays cannot interleave on the shared connection.
   */
  historyTranscript(sessionID: string): Promise<AgentConversationMessage[] | null> {
    const loaded = this.snapshot.conversations[sessionID];
    if (loaded?.hasCompleteHistory === true) return Promise.resolve(loaded.messages);
    if (!this.canExportTranscript(sessionID) || this.connection === null) {
      return Promise.resolve(null);
    }
    const queued = this.transcriptPending > 0;
    this.transcriptPending += 1;
    const run = queued
      ? this.transcriptChain.then(() => this.loadTranscript(sessionID))
      : this.loadTranscript(sessionID);
    this.transcriptChain = run
      .then(
        () => undefined,
        () => undefined,
      )
      .then(() => {
        this.transcriptPending -= 1;
      });
    return run;
  }

  private loadTranscript(sessionID: string): Promise<AgentConversationMessage[] | null> {
    const loaded = this.snapshot.conversations[sessionID];
    if (loaded?.hasCompleteHistory === true) return Promise.resolve(loaded.messages);
    if (this.connection === null) return Promise.resolve(null);
    return new Promise((resolve) => {
      const token = this.beginLoad(sessionID, true);
      if (token === null) {
        resolve(null);
        return;
      }
      this.transcriptWaiters.set(token, resolve);
    });
  }

  /** One export load finished; a failed or dropped load resolves with null. */
  private finishTranscript(token: string, sessionID: string): void {
    const resolve = this.transcriptWaiters.get(token);
    if (resolve === undefined) return;
    this.transcriptWaiters.delete(token);
    this.quietLoadTokens.delete(token);
    resolve(this.snapshot.conversations[sessionID]?.messages ?? []);
  }

  private failTranscript(token: string): void {
    const resolve = this.transcriptWaiters.get(token);
    if (resolve === undefined) return;
    this.transcriptWaiters.delete(token);
    this.quietLoadTokens.delete(token);
    resolve(null);
  }

  /** An export that cannot finish resolves with null rather than hanging. */
  private failTranscripts(): void {
    for (const token of this.transcriptWaiters.keys()) this.failTranscript(token);
    this.quietLoadTokens.clear();
  }
  // MARK: Conversations

  startNewConversation(): void {
    if (this.snapshot.isCreatingSession) return;
    this.update({ selectedSessionID: null, errorMessage: null });
    this.prepareConversation();
  }

  /** Prepare an empty session so upstream settings exist before the first prompt. */
  prepareConversation(): void {
    if (this.snapshot.connectionState.status !== "ready") return;
    const selected = this.snapshot.selectedSessionID;
    if (selected !== null) {
      if (this.snapshot.conversations[selected]?.isAttached !== true) this.selectSession(selected);
      return;
    }
    if (this.createToken !== null) return;
    const token = this.makeToken();
    this.createToken = token;
    this.update({ isCreatingSession: true });
    if (!this.sendCommand({ kind: "newSession", token })) {
      this.createToken = null;
      this.update({ isCreatingSession: false });
    }
  }

  selectSession(sessionID: string): void {
    const open = this.snapshot.openSessionIDs.includes(sessionID)
      ? this.snapshot.openSessionIDs
      : [...this.snapshot.openSessionIDs, sessionID];
    this.update({ selectedSessionID: sessionID, errorMessage: null, openSessionIDs: open });
    const conversation = this.snapshot.conversations[sessionID];
    if (
      conversation?.isAttached !== true &&
      conversation?.isLoading !== true &&
      this.connection !== null &&
      this.snapshot.canLoadSessions
    ) {
      this.beginLoad(sessionID);
    }
  }

  /**
   * Close a conversation tab. One that is still responding, loading, or waiting
   * for a permission decision stays open so its outcome is not lost.
   */
  closeConversation(sessionID: string): void {
    const conversation = this.snapshot.conversations[sessionID];
    if (
      conversation === undefined ||
      conversation.isResponding ||
      conversation.isLoading ||
      conversation.pendingConfigToken !== null ||
      currentPermission(conversation) !== null
    ) {
      return;
    }
    const conversations = { ...this.snapshot.conversations };
    delete conversations[sessionID];
    const open = this.snapshot.openSessionIDs.filter((id) => id !== sessionID);
    this.pendingText.delete(sessionID);
    this.queuedPrompts.delete(sessionID);
    this.unpromptedSessionIDs.delete(sessionID);
    this.update({
      conversations,
      openSessionIDs: open,
      selectedSessionID:
        this.snapshot.selectedSessionID === sessionID
          ? (open[open.length - 1] ?? null)
          : this.snapshot.selectedSessionID,
    });
  }

  /** Queue one turn, waiting for a fresh or loading session when needed. */
  send(text: string, files: string[] = []): void {
    const prompt: AgentPrompt = {
      text: text.trim(),
      files: addFileReferences([], files),
      submittedAt: this.now(),
    };
    if (prompt.text.length === 0 && prompt.files.length === 0) return;
    if (this.connection === null) throw new AgentConnectionBusyError("The Agent is not connected.");

    const sessionID = this.snapshot.selectedSessionID;
    if (sessionID === null) {
      if (this.createToken === null) this.prepareConversation();
      const token = this.createToken;
      if (token === null) throw new AgentConnectionBusyError("The Agent is not connected.");
      this.queuedPrompts.set(token, prompt);
      this.update({
        pendingNewConversationPrompt: promptDisplayText(prompt),
        pendingNewConversationStartedAt: prompt.submittedAt,
        errorMessage: null,
      });
      return;
    }

    const conversation = this.snapshot.conversations[sessionID] ?? createConversation();
    if (conversation.isResponding) {
      throw new AgentConnectionBusyError("The Agent is still responding in this conversation.");
    }
    if (conversation.pendingConfigToken !== null) {
      throw new AgentConnectionBusyError("A configuration change is still pending.");
    }
    if (conversation.isLoading) {
      this.queuedPrompts.set(sessionID, prompt);
    } else if (conversation.isAttached) {
      if (!this.startPrompt(prompt, sessionID)) {
        throw new AgentConnectionBusyError(this.snapshot.errorMessage ?? "The Agent is not connected.");
      }
    } else if (this.snapshot.canLoadSessions) {
      this.queuedPrompts.set(sessionID, prompt);
      this.beginLoad(sessionID);
    } else {
      throw new AgentConnectionBusyError(
        "This conversation cannot be resumed, so it cannot be prompted again.",
      );
    }
  }

  cancel(): void {
    const sessionID = this.snapshot.selectedSessionID;
    if (sessionID === null) return;
    const conversation = this.snapshot.conversations[sessionID];
    if (conversation?.isResponding !== true || conversation.isCancelling) return;
    this.editConversation(sessionID, (current) => ({
      ...current,
      isCancelling: true,
      pendingPermissions: [],
    }));
    if (!this.sendCommand({ kind: "cancel", sessionId: sessionID })) {
      this.editConversation(sessionID, (current) => ({ ...current, isCancelling: false }));
    }
  }

  answerPermission(optionID: string | null): void {
    const sessionID = this.snapshot.selectedSessionID;
    if (sessionID === null) return;
    const conversation = this.snapshot.conversations[sessionID];
    const permission = conversation === undefined ? null : currentPermission(conversation);
    if (permission === null) return;
    this.editConversation(sessionID, (current) => ({
      ...current,
      pendingPermissions: current.pendingPermissions.slice(1),
    }));
    this.sendCommand({ kind: "permission", requestId: permission.id, optionId: optionID });
  }

  setConfigOption(id: string, value: string): void {
    const sessionID = this.snapshot.selectedSessionID;
    if (sessionID === null) return;
    const conversation = this.snapshot.conversations[sessionID];
    if (conversation === undefined) return;
    const option = conversation.configOptions.find((entry) => entry.id === id);
    if (
      !conversation.isAttached ||
      conversation.isResponding ||
      conversation.isLoading ||
      conversation.pendingConfigToken !== null ||
      option === undefined ||
      option.currentValue === value ||
      !option.choices.some((choice) => choice.id === value)
    ) {
      return;
    }
    const token = this.makeToken();
    this.editConversation(sessionID, (current) => ({
      ...current,
      pendingConfigToken: token,
      configurationError: null,
    }));
    if (
      !this.sendCommand({
        kind: "setConfigOption",
        token,
        sessionId: sessionID,
        configId: id,
        value,
      })
    ) {
      this.editConversation(sessionID, (current) => ({ ...current, pendingConfigToken: null }));
    }
  }
  // MARK: Events

  /** Reduce one event from the host. Unknown kinds are ignored, never guessed. */
  receive(event: unknown): void {
    if (!isRecord(event)) return;
    const kind = asString(event.kind);
    const sessionID = asString(event.sessionId);
    const token = asString(event.token);
    switch (kind) {
      case "authenticationRequired":
        if (!this.snapshot.usesSubscription) return;
        this.update({ connectionState: { status: "authenticationRequired" } });
        return;
      case "authenticating":
        if (!this.snapshot.usesSubscription) return;
        this.update({ connectionState: { status: "authenticating" } });
        return;
      case "account": {
        if (!this.snapshot.usesSubscription || !isRecord(event.account)) return;
        this.update({
          subscriptionEmail: asString(event.account.email),
          subscriptionPlan: asString(event.account.plan),
        });
        return;
      }
      case "quota": {
        if (!this.snapshot.usesSubscription) return;
        if (this.snapshot.connectionState.status !== "ready") return;
        const quota = parseSubscriptionQuota(event.snapshot);
        if (quota === null) {
          this.update({ quotaFailure: "unparsable" });
        } else {
          this.update({ subscriptionQuota: quota, quotaFailure: null });
        }
        return;
      }
      case "quotaFailed": {
        if (!this.snapshot.usesSubscription) return;
        if (this.snapshot.connectionState.status !== "ready") return;
        const code = asString(event.code) ?? "unavailable";
        // A changed or unauthorized account invalidates the previous numbers.
        const drop = code === "accountChanged" || code === "unauthorized";
        this.update({
          quotaFailure: code,
          subscriptionQuota: drop ? null : this.snapshot.subscriptionQuota,
        });
        return;
      }
      case "ready":
        this.canListSessions = event.canListSessions === true;
        this.update({
          connectionState: { status: "ready" },
          agentName: asString(event.agentName),
          agentVersion: asString(event.agentVersion),
          canLoadSessions: event.canLoadSessions === true,
        });
        this.refreshSessions();
        return;
      case "sessions": {
        if (!this.snapshot.isRefreshingSessions || token !== this.historyRefreshToken) return;
        this.mergeSessions(Array.isArray(event.sessions) ? event.sessions : []);
        this.historyRefreshToken = null;
        this.update({ isRefreshingSessions: false });
        return;
      }
      case "sessionCreated": {
        if (sessionID === null || token === null || token !== this.createToken) return;
        this.createToken = null;
        this.editConversation(sessionID, (current) => ({
          ...current,
          configOptions: parseSessionConfigOptions(event.configOptions),
        }));
        this.sessionCreated(sessionID, token);
        return;
      }
      case "sessionLoaded": {
        if (sessionID === null || token === null) return;
        if (!this.loadTokens.delete(token)) return;
        this.unpromptedSessionIDs.delete(sessionID);
        this.flushPendingText();
        this.editConversation(sessionID, (current) => ({
          ...current,
          isLoading: false,
          isAttached: true,
          hasCompleteHistory: true,
          configOptions: parseSessionConfigOptions(event.configOptions),
        }));
        this.loadBackups.delete(sessionID);
        // An export load collected the transcript without adding a tab.
        if (!this.quietLoadTokens.delete(token)) this.openTab(sessionID);
        this.finishTranscript(token, sessionID);
        const prompt = this.queuedPrompts.get(sessionID);
        if (prompt !== undefined) {
          this.queuedPrompts.delete(sessionID);
          this.startPrompt(prompt, sessionID);
        }
        return;
      }
      case "sessionConfigured": {
        if (sessionID === null) return;
        const conversation = this.snapshot.conversations[sessionID];
        if (conversation === undefined || conversation.pendingConfigToken !== token) return;
        this.applyConfiguration(event.configOptions, sessionID);
        this.editConversation(sessionID, (current) => ({ ...current, pendingConfigToken: null }));
        return;
      }
      case "turnCancelling":
        if (sessionID === null) return;
        this.editConversation(sessionID, (current) => ({ ...current, isCancelling: true }));
        return;
      case "update": {
        if (sessionID === null || !isRecord(event.update)) return;
        this.apply(event.update, sessionID);
        return;
      }
      case "permission": {
        if (sessionID === null) return;
        const conversation = this.snapshot.conversations[sessionID];
        if (conversation?.isCancelling === true) return;
        const requestID = asString(event.requestId);
        if (requestID === null) return;
        const prompt = permissionPrompt(conversation ?? createConversation(), requestID, event.request);
        this.editConversation(sessionID, (current) => enqueuePermission(current, prompt));
        return;
      }
      case "turnFinished": {
        this.refreshQuota();
        if (sessionID === null) return;
        const stopReason = asString(event.stopReason);
        this.flushPendingText();
        const usage = parseTurnUsage(event.usage);
        this.editConversation(sessionID, (current) => ({
          ...interruptPendingTools(finishActiveTurn(current, this.now(), usage)),
          isResponding: false,
          isCancelling: false,
          pendingPermissions: [],
          errorMessage: stopReasonMessage(stopReason),
        }));
        return;
      }
      case "requestFailed":
        this.requestFailed(token, sessionID, asString(event.message) ?? "The Agent request failed.");
        return;
      case "stopped": {
        const message = asString(event.message) ?? "The Agent connection closed unexpectedly.";
        const old = this.detachConnection({ status: "failed", message });
        if (old !== null) {
          const closing = old.close().catch(() => undefined);
          this.closePromise = closing;
          void closing.then(() => {
            if (this.closePromise === closing) this.closePromise = null;
          });
        }
        return;
      }
      default:
        return;
    }
  }

  private sessionCreated(sessionID: string, token: string): void {
    const prompt = this.queuedPrompts.get(token);
    this.queuedPrompts.delete(token);
    if (!this.snapshot.sessions.some((session) => session.id === sessionID)) {
      const title = prompt === undefined ? null : provisionalTitle(promptDisplayText(prompt));
      this.update({ sessions: [{ id: sessionID, title, updatedAt: null }, ...this.snapshot.sessions] });
    }
    this.editConversation(sessionID, (current) => ({
      ...current,
      isAttached: true,
      hasCompleteHistory: true,
    }));
    this.unpromptedSessionIDs.add(sessionID);
    this.openTab(sessionID);
    this.update({
      pendingNewConversationPrompt: null,
      pendingNewConversationStartedAt: null,
      isCreatingSession: false,
      selectedSessionID: this.snapshot.selectedSessionID ?? sessionID,
    });
    if (prompt !== undefined) this.startPrompt(prompt, sessionID);
  }
  /** Route a failure to the request it belongs to, identified by its token. */
  private requestFailed(token: string | null, sessionID: string | null, message: string): void {
    if (token !== null && token === this.historyRefreshToken) {
      this.historyRefreshToken = null;
      this.update({ isRefreshingSessions: false, historyError: message });
      return;
    }
    if (
      sessionID !== null &&
      token !== null &&
      this.snapshot.conversations[sessionID]?.pendingConfigToken === token
    ) {
      this.editConversation(sessionID, (current) => ({
        ...current,
        pendingConfigToken: null,
        configurationError: message,
      }));
      return;
    }
    if (token !== null && token === this.createToken) {
      this.queuedPrompts.delete(token);
      this.createToken = null;
      this.update({
        pendingNewConversationPrompt: null,
        pendingNewConversationStartedAt: null,
        isCreatingSession: false,
        errorMessage: message,
      });
      return;
    }
    const loading = token === null ? undefined : this.loadTokens.get(token);
    if (token !== null && loading !== undefined) {
      this.loadTokens.delete(token);
      this.queuedPrompts.delete(loading);
      this.pendingText.delete(loading);
      const backup = this.loadBackups.get(loading);
      if (backup !== undefined) this.setConversation(loading, backup);
      this.loadBackups.delete(loading);
      this.editConversation(loading, (current) => ({
        ...current,
        isLoading: false,
        errorMessage: message,
      }));
      this.failTranscript(token);
      return;
    }
    if (sessionID !== null && this.snapshot.conversations[sessionID] !== undefined) {
      this.flushPendingText();
      this.editConversation(sessionID, (current) => ({
        ...interruptPendingTools(finishActiveTurn(current, this.now())),
        isResponding: false,
        isCancelling: false,
        pendingPermissions: [],
        errorMessage: message,
      }));
      return;
    }
    this.update({ errorMessage: message });
  }

  private mergeSessions(entries: unknown[]): void {
    const listed: AgentSessionSummary[] = entries.flatMap((entry) => {
      if (!isRecord(entry)) return [];
      const id = asString(entry.sessionId);
      if (id === null) return [];
      const local = this.snapshot.sessions.find((session) => session.id === id);
      return [
        {
          id,
          title: asString(entry.title) ?? local?.title ?? null,
          updatedAt: asString(entry.updatedAt),
        },
      ];
    });
    const listedIDs = new Set(listed.map((session) => session.id));
    // A listed session is owned by upstream history even if the transcript is empty.
    for (const id of listedIDs) this.unpromptedSessionIDs.delete(id);
    // Sessions created in this run may not be persisted by the agent yet.
    const localOnly = this.snapshot.sessions.filter(
      (session) =>
        !listedIDs.has(session.id) && this.snapshot.conversations[session.id] !== undefined,
    );
    this.update({ sessions: [...localOnly, ...listed] });
  }

  private apply(update: Record<string, unknown>, sessionID: string): void {
    switch (asString(update.sessionUpdate)) {
      case "usage_update":
        if (this.snapshot.connectionState.status !== "ready") return;
        this.editConversation(sessionID, (current) => ({
          ...current,
          contextUsage: parseContextUsage(update),
        }));
        return;
      case "config_option_update":
        this.applyConfiguration(update.configOptions, sessionID);
        return;
      case "agent_message_chunk": {
        const text = updateText(update);
        if (text === null) return;
        this.pendingText.set(sessionID, (this.pendingText.get(sessionID) ?? "") + text);
        this.scheduler.schedule(() => this.flushPendingText());
        return;
      }
      case "user_message_chunk": {
        const text = updateText(update);
        if (text === null) return;
        this.flushPendingText();
        this.editConversation(sessionID, (current) => appendMessage(current, "user", text));
        return;
      }
      case "tool_call":
      case "tool_call_update": {
        const toolCallID = asString(update.toolCallId);
        if (toolCallID === null) return;
        this.flushPendingText();
        this.editConversation(sessionID, (current) => upsertToolMessage(current, toolCallID, update));
        return;
      }
      case "session_info_update": {
        const title = asString(update.title);
        if (title === null || title.length === 0) return;
        const index = this.snapshot.sessions.findIndex((session) => session.id === sessionID);
        if (index >= 0) {
          const sessions = this.snapshot.sessions.slice();
          sessions[index] = { ...sessions[index], title };
          this.update({ sessions });
        } else {
          this.update({
            sessions: [{ id: sessionID, title, updatedAt: null }, ...this.snapshot.sessions],
          });
        }
        return;
      }
      default:
        return;
    }
  }

  /**
   * A model change resets context occupancy: the previous window size and used
   * tokens belonged to the model that produced them.
   */
  private applyConfiguration(value: unknown, sessionID: string): void {
    const options = parseSessionConfigOptions(value);
    const previous = this.snapshot.conversations[sessionID];
    const oldModels = (previous?.configOptions ?? []).filter((option) => option.category === "model");
    const newModels = options.filter((option) => option.category === "model");
    const changed =
      oldModels.map((option) => option.currentValue).join("\u0000") !==
      newModels.map((option) => option.currentValue).join("\u0000");
    this.editConversation(sessionID, (current) => ({
      ...current,
      configOptions: options,
      contextUsage: changed ? null : current.contextUsage,
    }));
  }

  private flushPendingText(): void {
    if (this.pendingText.size === 0) return;
    const batches = [...this.pendingText.entries()];
    this.pendingText.clear();
    for (const [sessionID, text] of batches) {
      if (text.length === 0) continue;
      this.editConversation(sessionID, (current) => appendMessage(current, "agent", text));
    }
  }
  /** Returns false when the command could not be queued, leaving the draft intact. */
  private startPrompt(prompt: AgentPrompt, sessionID: string): boolean {
    const command: Record<string, unknown> = {
      kind: "prompt",
      sessionId: sessionID,
      text: prompt.text,
    };
    if (prompt.files.length > 0) command.files = prompt.files;
    if (!this.sendCommand(command)) return false;
    this.unpromptedSessionIDs.delete(sessionID);
    this.editConversation(sessionID, (current) => {
      const next = appendMessage(
        { ...current, isResponding: true, errorMessage: null },
        "user",
        promptDisplayText(prompt),
      );
      const message = next.messages[next.messages.length - 1];
      return { ...next, activeTurn: startTurn(message.id, prompt.submittedAt) };
    });
    return true;
  }

  /**
   * Start loading one session. `quiet` keeps an export load out of the tab bar;
   * the token is returned so the caller can register its own waiter, or `null`
   * when the command could not even be queued.
   */
  private beginLoad(sessionID: string, quiet = false): string | null {
    const token = this.makeToken();
    this.loadTokens.set(token, sessionID);
    if (quiet) this.quietLoadTokens.add(token);
    this.loadBackups.set(sessionID, this.snapshot.conversations[sessionID] ?? createConversation());
    this.pendingText.delete(sessionID);
    // The agent replays the whole history, so rebuild it from scratch.
    this.setConversation(sessionID, { ...createConversation(), isLoading: true });
    if (!this.sendCommand({ kind: "loadSession", token, sessionId: sessionID })) {
      this.requestFailed(token, sessionID, this.snapshot.errorMessage ?? "The Agent request failed.");
      return null;
    }
    return token;
  }

  private openTab(sessionID: string): void {
    if (this.snapshot.openSessionIDs.includes(sessionID)) return;
    this.update({ openSessionIDs: [...this.snapshot.openSessionIDs, sessionID] });
  }

  /** Returns false and records the error when the command could not be queued. */
  private sendCommand(command: Record<string, unknown>): boolean {
    const connection = this.connection;
    if (connection === null) {
      this.update({ errorMessage: "The Agent is not connected." });
      return false;
    }
    // The host orders commands per connection, so the outcome arrives through
    // the event stream (`requestFailed`) rather than this promise.
    void connection.send(command).catch((error: unknown) => {
      this.update({ errorMessage: messageOf(error) });
    });
    return true;
  }

  /** Clears connection state; returns the connection that still has to be closed. */
  private detachConnection(
    failure: { status: "failed"; message: string } | null,
  ): AgentTransportConnection | null {
    this.flushPendingText();
    this.scheduler.cancel();
    // Events still buffered for the old connection must not be applied.
    this.stale = true;
    const old = this.connection;
    this.connection = null;
    this.canListSessions = false;
    this.historyRefreshToken = null;
    this.queuedPrompts.clear();
    this.loadTokens.clear();
    this.failTranscripts();
    const conversations = { ...this.snapshot.conversations };
    for (const [id, backup] of this.loadBackups) conversations[id] = backup;
    this.loadBackups.clear();
    // A conversation only prepared to hold upstream settings has nothing to
    // resume after the process is gone, so it must not reappear as history.
    for (const session of this.unpromptedSessionIDs) {
      const conversation = conversations[session];
      if (conversation !== undefined && conversation.messages.length === 0) delete conversations[session];
    }
    this.unpromptedSessionIDs.clear();
    const now = this.now();
    for (const id of Object.keys(conversations)) {
      conversations[id] = { ...finishActiveTurn(conversations[id], now), contextUsage: null };
    }
    this.createToken = null;
    this.update({
      conversations,
      connectionState: failure ?? { status: "idle" },
      subscriptionQuota: null,
      subscriptionEmail: null,
      subscriptionPlan: null,
      quotaFailure: null,
      canLoadSessions: false,
      isRefreshingSessions: false,
      pendingNewConversationPrompt: null,
      pendingNewConversationStartedAt: null,
      isCreatingSession: false,
    });
    return old;
  }
}
