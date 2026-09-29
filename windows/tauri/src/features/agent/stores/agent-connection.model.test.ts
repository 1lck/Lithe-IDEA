import { beforeEach, describe, expect, test } from "bun:test";
import fixture from "../../../../../../shared/fixtures/agent/acp-events-v1.json";
import {
  AgentConnectionBusyError,
  AgentConnectionModel,
  type AgentFlushScheduler,
} from "./agent-connection.model";
import type {
  AgentLaunchConfiguration,
  AgentTransport,
  AgentTransportConnection,
} from "../services/agent-transport";
import { currentPermission } from "../types/agent.types";

/** Records the commands the panel queued and lets a test replay host events. */
class ScriptedTransport implements AgentTransport {
  readonly commands: Record<string, unknown>[] = [];
  closes = 0;
  openFailure: Error | null = null;
  private deliver: ((event: unknown) => void) | null = null;

  open(
    _connectionID: string,
    _launch: AgentLaunchConfiguration,
    onEvent: (event: unknown) => void,
  ): Promise<AgentTransportConnection> {
    if (this.openFailure) return Promise.reject(this.openFailure);
    this.deliver = onEvent;
    return Promise.resolve({
      send: (command) => {
        this.commands.push(command as Record<string, unknown>);
        return Promise.resolve();
      },
      close: () => {
        this.closes += 1;
        return Promise.resolve();
      },
    });
  }

  emit(event: unknown): void {
    this.deliver?.(event);
  }

  command(kind: string): Record<string, unknown> | undefined {
    return this.commands.find((command) => command.kind === kind);
  }
}

/** Streaming batches only when the panel asks for a flush, so tests stay ordered. */
function manualScheduler(): AgentFlushScheduler & { flush(): void } {
  let pending: (() => void) | null = null;
  return {
    schedule(callback) {
      pending = callback;
    },
    cancel() {
      pending = null;
    },
    flush() {
      const run = pending;
      pending = null;
      run?.();
    },
  };
}

function launch(authentication: "apiKey" | "codexSubscription" = "apiKey"): AgentLaunchConfiguration {
  return {
    agentId: "codex-acp",
    command: null,
    args: [],
    cwd: "C:/project",
    dataDirectory: "C:/data",
    authentication,
    provider:
      authentication === "apiKey"
        ? { protocol: "responses", baseUrl: "https://gateway.example.com/v1", apiKey: "test-key" }
        : null,
  };
}

describe("Agent connection lifecycle", () => {
  let transport: ScriptedTransport;
  let scheduler: ReturnType<typeof manualScheduler>;
  let model: AgentConnectionModel;

  beforeEach(() => {
    transport = new ScriptedTransport();
    scheduler = manualScheduler();
    model = new AgentConnectionModel(transport, scheduler);
  });

  async function connectReady(): Promise<void> {
    await model.connect(launch());
    transport.emit(fixture.events.ready);
  }

  test("a refused launch is reported instead of leaving the panel connecting", async () => {
    transport.openFailure = new Error("codex-acp is not installed. Install it in Settings › Agents.");
    await expect(model.connect(launch())).rejects.toThrow(/not installed/);
    expect(model.getSnapshot().connectionState).toEqual({
      status: "failed",
      message: "codex-acp is not installed. Install it in Settings › Agents.",
    });
  });

  test("ready reports the agent and asks for the workspace history once", async () => {
    await connectReady();
    const snapshot = model.getSnapshot();
    expect(snapshot.connectionState).toEqual({ status: "ready" });
    expect(snapshot.agentName).toBe("example-agent");
    expect(snapshot.canLoadSessions).toBe(true);
    expect(transport.commands.filter((command) => command.kind === "listSessions")).toHaveLength(1);
  });

  test("a stale or unsolicited session list is ignored", async () => {
    await connectReady();
    transport.emit(fixture.events.sessions);
    expect(model.getSnapshot().sessions).toEqual([]);

    const token = transport.command("listSessions")?.token;
    transport.emit({ ...fixture.events.sessions, token });
    expect(model.getSnapshot().sessions.map((session) => session.id)).toEqual([
      "session-1",
      "session-2",
    ]);
    expect(model.getSnapshot().isRefreshingSessions).toBe(false);
  });

  test("a prompt sent before the session exists waits for it instead of failing", async () => {
    await connectReady();
    model.startNewConversation();
    const createToken = transport.command("newSession")?.token as string;
    expect(model.getSnapshot().isCreatingSession).toBe(true);

    model.send("Explain this project");
    expect(model.getSnapshot().pendingNewConversationPrompt).toBe("Explain this project");
    expect(transport.command("prompt")).toBeUndefined();

    transport.emit({ ...fixture.events.sessionCreated, token: createToken });
    expect(transport.command("prompt")).toEqual({
      kind: "prompt",
      sessionId: "session-1",
      text: "Explain this project",
    });
    const conversation = model.getSnapshot().conversations["session-1"];
    expect(conversation.isResponding).toBe(true);
    expect(conversation.messages.map((message) => message.role)).toEqual(["user"]);
    expect(model.getSnapshot().sessions[0]).toEqual({
      id: "session-1",
      title: "Explain this project",
      updatedAt: null,
    });
  });

  test("a session the agent never creates is not resumed after the process exits", async () => {
    await connectReady();
    model.startNewConversation();
    const createToken = transport.command("newSession")?.token as string;
    transport.emit({ ...fixture.events.sessionCreated, token: createToken });
    expect(model.getSnapshot().conversations["session-1"]).toBeDefined();

    transport.emit({ kind: "stopped", message: "The Agent exited." });
    expect(model.getSnapshot().conversations["session-1"]).toBeUndefined();
    expect(transport.closes).toBe(1);
  });

  test("streamed chunks are batched into one agent message", async () => {
    await connectReady();
    model.startNewConversation();
    transport.emit({
      ...fixture.events.sessionCreated,
      token: transport.command("newSession")?.token,
    });

    transport.emit(fixture.events.agentMessageChunk);
    transport.emit({
      ...fixture.events.agentMessageChunk,
      update: { ...fixture.events.agentMessageChunk.update, content: { type: "text", text: " And more." } },
    });
    expect(model.getSnapshot().conversations["session-1"].messages).toHaveLength(0);

    scheduler.flush();
    const messages = model.getSnapshot().conversations["session-1"].messages;
    expect(messages).toHaveLength(1);
    expect(messages[0].text).toBe("This project **builds** an IDE. And more.");
  });

  test("tool evidence accumulates across partial updates", async () => {
    await connectReady();
    model.startNewConversation();
    transport.emit({
      ...fixture.events.sessionCreated,
      token: transport.command("newSession")?.token,
    });

    transport.emit(fixture.events.toolCall);
    transport.emit(fixture.events.toolCallUpdate);
    const messages = model.getSnapshot().conversations["session-1"].messages;
    expect(messages).toHaveLength(1);
    expect(messages[0].toolStatus).toBe("completed");
    expect(messages[0].toolDetails.output).toContain("exitCode");
  });

  test("a permission request is answered by option id, including a refusal", async () => {
    await connectReady();
    model.startNewConversation();
    transport.emit({
      ...fixture.events.sessionCreated,
      token: transport.command("newSession")?.token,
    });

    transport.emit(fixture.events.permission);
    const conversation = model.getSnapshot().conversations["session-1"];
    expect(currentPermission(conversation)?.title).toBe("Run tests");

    model.answerPermission("allow_once");
    expect(transport.command("permission")).toEqual({
      kind: "permission",
      requestId: "permission-1",
      optionId: "allow_once",
    });
    expect(currentPermission(model.getSnapshot().conversations["session-1"])).toBeNull();

    transport.emit(fixture.events.permission);
    model.answerPermission(null);
    expect(transport.commands.filter((command) => command.kind === "permission")).toHaveLength(2);
    expect(transport.commands[transport.commands.length - 1].optionId).toBeNull();
  });

  test("a cancelled turn stops responding and says why", async () => {
    await connectReady();
    model.startNewConversation();
    transport.emit({
      ...fixture.events.sessionCreated,
      token: transport.command("newSession")?.token,
    });
    model.send("Explain this project");
    expect(() => model.send("again")).toThrow(AgentConnectionBusyError);

    model.cancel();
    expect(transport.command("cancel")).toEqual({ kind: "cancel", sessionId: "session-1" });
    expect(model.getSnapshot().conversations["session-1"].isCancelling).toBe(true);

    transport.emit(fixture.events.turnCancelled);
    const conversation = model.getSnapshot().conversations["session-1"];
    expect(conversation.isResponding).toBe(false);
    expect(conversation.isCancelling).toBe(false);
    expect(conversation.errorMessage).toBe("The response was cancelled.");
  });

  test("a failed request is routed to the request it belongs to", async () => {
    await connectReady();
    model.startNewConversation();
    const createToken = transport.command("newSession")?.token as string;
    model.send("Explain this project");

    transport.emit({
      kind: "requestFailed",
      token: createToken,
      sessionId: null,
      message: "The Agent is still responding in this conversation",
    });
    expect(model.getSnapshot().errorMessage).toBe("The Agent is still responding in this conversation");
    expect(model.getSnapshot().pendingNewConversationPrompt).toBeNull();
    expect(model.getSnapshot().isCreatingSession).toBe(false);
  });

  test("an unusable subscription snapshot is reported rather than shown as usage", async () => {
    await model.connect(launch("codexSubscription"));
    transport.emit(fixture.events.ready);
    transport.emit({ ...fixture.events.quota, snapshot: { windows: [], fetchedAt: 1 } });
    expect(model.getSnapshot().subscriptionQuota).toBeNull();
    expect(model.getSnapshot().quotaFailure).toBe("unparsable");

    transport.emit(fixture.events.quota);
    expect(model.getSnapshot().subscriptionQuota?.windows).toHaveLength(1);
    expect(model.getSnapshot().quotaFailure).toBeNull();
  });

  test("subscription events are ignored on an API-key connection", async () => {
    await connectReady();
    transport.emit(fixture.events.authenticationRequired);
    transport.emit(fixture.events.account);
    transport.emit(fixture.events.quota);
    expect(model.getSnapshot().connectionState).toEqual({ status: "ready" });
    expect(model.getSnapshot().subscriptionEmail).toBeNull();
    expect(model.getSnapshot().subscriptionQuota).toBeNull();
  });

  test("context occupancy is cleared when the model changes", async () => {
    await connectReady();
    model.startNewConversation();
    transport.emit({
      ...fixture.events.sessionCreated,
      token: transport.command("newSession")?.token,
    });
    transport.emit(fixture.events.usageUpdate);
    expect(model.getSnapshot().conversations["session-1"].contextUsage?.usedTokens).toBe(18700);

    // The host publishes the selectable models before the panel changes one.
    const modelOptions = [
      {
        id: "model",
        name: "Model",
        category: "model",
        type: "select",
        currentValue: "example-model",
        options: [
          { value: "example-model", name: "Example Model" },
          { value: "other-model", name: "Other Model" },
        ],
      },
    ];
    transport.emit({
      kind: "update",
      sessionId: "session-1",
      update: { sessionUpdate: "config_option_update", configOptions: modelOptions },
    });

    model.setConfigOption("model", "other-model");
    const token = transport.command("setConfigOption")?.token as string;
    transport.emit({
      ...fixture.events.sessionConfigured,
      token,
      configOptions: [{ ...modelOptions[0], currentValue: "other-model" }],
    });
    expect(model.getSnapshot().conversations["session-1"].configOptions[0].currentValue).toBe("other-model");
    expect(model.getSnapshot().conversations["session-1"].contextUsage).toBeNull();
  });

  test("stopping releases the connection and is safe to repeat", async () => {
    await connectReady();
    await model.stop();
    await model.stop();
    expect(transport.closes).toBe(1);
    expect(model.getSnapshot().connectionState).toEqual({ status: "idle" });
    expect(model.hasActiveConnection).toBe(false);
  });
});

describe("Agent transcript export", () => {
  let transport: ScriptedTransport;
  let scheduler: ReturnType<typeof manualScheduler>;
  let model: AgentConnectionModel;

  beforeEach(() => {
    transport = new ScriptedTransport();
    scheduler = manualScheduler();
    model = new AgentConnectionModel(transport, scheduler);
  });

  async function connectReady(): Promise<void> {
    await model.connect(launch());
    transport.emit(fixture.events.ready);
  }

  function loadCommands(): Record<string, unknown>[] {
    return transport.commands.filter((command) => command.kind === "loadSession");
  }

  test("an export load replays the transcript without opening a tab", async () => {
    await connectReady();
    const pending = model.historyTranscript("session-2");
    const token = transport.command("loadSession")?.token as string;
    transport.emit({ ...fixture.events.userMessageChunk, sessionId: "session-2" });
    transport.emit({ ...fixture.events.agentMessageChunk, sessionId: "session-2" });
    transport.emit({ kind: "sessionLoaded", token, sessionId: "session-2" });

    expect((await pending)?.map((message) => message.text)).toEqual([
      "Explain this project",
      "This project **builds** an IDE.",
    ]);
    expect(model.getSnapshot().openSessionIDs).toEqual([]);
    expect(model.getSnapshot().selectedSessionID).toBeNull();
  });

  test("a failed export load resolves with null instead of hanging", async () => {
    await connectReady();
    const pending = model.historyTranscript("session-2");
    const token = transport.command("loadSession")?.token as string;
    transport.emit({ kind: "requestFailed", token, sessionId: "session-2", message: "load failed" });
    expect(await pending).toBeNull();
    expect(model.getSnapshot().openSessionIDs).toEqual([]);
  });

  test("a connection dropped mid-load resolves null rather than never finishing", async () => {
    await connectReady();
    const pending = model.historyTranscript("session-2");
    transport.emit({ kind: "stopped", message: "gone" });
    expect(await pending).toBeNull();
  });

  test("an already replayed session is reused instead of loaded twice", async () => {
    await connectReady();
    const first = model.historyTranscript("session-2");
    const token = transport.command("loadSession")?.token as string;
    transport.emit({ kind: "sessionLoaded", token, sessionId: "session-2" });
    await first;
    await model.historyTranscript("session-2");
    expect(loadCommands()).toHaveLength(1);
  });

  test("two export loads stay sequential on the shared connection", async () => {
    await connectReady();
    const first = model.historyTranscript("session-1");
    const second = model.historyTranscript("session-2");
    expect(loadCommands()).toHaveLength(1);

    transport.emit({ kind: "sessionLoaded", token: loadCommands()[0].token, sessionId: "session-1" });
    await first;
    for (let attempt = 0; attempt < 5 && loadCommands().length < 2; attempt += 1) {
      await Promise.resolve();
    }
    expect(loadCommands()).toHaveLength(2);

    transport.emit({ kind: "sessionLoaded", token: loadCommands()[1].token, sessionId: "session-2" });
    expect(await second).toEqual([]);
  });

  test("a session the connection cannot replay is refused instead of guessed", async () => {
    expect(model.canExportTranscript("session-1")).toBe(false);
    expect(await model.historyTranscript("session-1")).toBeNull();
  });
});
