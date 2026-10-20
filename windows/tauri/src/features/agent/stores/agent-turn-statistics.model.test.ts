import { describe, expect, test } from "bun:test";
import fixture from "../../../../../../shared/fixtures/agent/acp-events-v1.json";
import { AgentConnectionModel, type AgentFlushScheduler } from "./agent-connection.model";
import type {
  AgentLaunchConfiguration,
  AgentTransport,
  AgentTransportConnection,
} from "../services/agent-transport";
import { formatTurnDuration, parseTurnUsage } from "../types/agent-turn-statistics";

/** Records commands and replays host events in the order a test chooses. */
class ScriptedTransport implements AgentTransport {
  readonly commands: Record<string, unknown>[] = [];
  private deliver: ((event: unknown) => void) | null = null;

  open(
    _connectionID: string,
    _launch: AgentLaunchConfiguration,
    onEvent: (event: unknown) => void,
  ): Promise<AgentTransportConnection> {
    this.deliver = onEvent;
    return Promise.resolve({
      send: (command) => {
        this.commands.push(command as Record<string, unknown>);
        return Promise.resolve();
      },
      close: () => Promise.resolve(),
    });
  }

  emit(event: unknown): void {
    this.deliver?.(event);
  }

  token(kind: string): string {
    return this.commands.find((command) => command.kind === kind)?.token as string;
  }
}

const immediate: AgentFlushScheduler = {
  schedule: (callback) => callback(),
  cancel: () => undefined,
};

const LAUNCH: AgentLaunchConfiguration = {
  agentId: "codex-acp",
  command: null,
  args: [],
  cwd: "C:/project",
  dataDirectory: "C:/data",
  authentication: "apiKey",
  provider: {
    protocol: "responses",
    baseUrl: "https://gateway.example.com/v1",
    apiKey: "test-key",
  },
};

/** A model whose clock only moves when the test advances it. */
async function readyModel() {
  const transport = new ScriptedTransport();
  let clock = 1_000;
  const model = new AgentConnectionModel(transport, immediate, () => clock);
  await model.connect(LAUNCH);
  transport.emit(fixture.events.ready);
  model.startNewConversation();
  transport.emit({ ...fixture.events.sessionCreated, token: transport.token("newSession") });
  return {
    transport,
    model,
    advance(milliseconds: number) {
      clock += milliseconds;
    },
  };
}

describe("Agent turn statistics", () => {
  test("a finished turn freezes its elapsed time and the Agent's token counts", async () => {
    const { transport, model, advance } = await readyModel();
    model.send("Explain this project");
    const started = model.getSnapshot().conversations["session-1"];
    expect(started.activeTurn?.startedAt).toBe(1_000);
    expect(started.activeTurn?.id).toBe(started.messages[0].id);

    advance(2_500);
    transport.emit(fixture.events.agentMessageChunk);
    advance(1_500);
    transport.emit(fixture.events.turnFinishedWithUsage);

    const finished = model.getSnapshot().conversations["session-1"];
    expect(finished.activeTurn).toBeNull();
    expect(finished.completedTurns).toHaveLength(1);
    const [turn] = finished.completedTurns;
    expect(turn.duration).toBe(4);
    // The summary belongs after the reply, not after the user's prompt.
    expect(turn.endingMessageID).toBe(finished.messages[1].id);
    expect(turn.usage).toEqual({
      totalTokens: 25000,
      inputTokens: 18000,
      outputTokens: 2000,
      thoughtTokens: 1000,
      cachedReadTokens: 3000,
      cachedWriteTokens: 1000,
    });
  });

  test("a failed or disconnected turn still records its time but no usage", async () => {
    const { transport, model, advance } = await readyModel();
    model.send("First");
    advance(1_000);
    transport.emit({ kind: "requestFailed", sessionId: "session-1", message: "Gateway refused" });
    expect(model.getSnapshot().conversations["session-1"].completedTurns[0]).toMatchObject({
      duration: 1,
      usage: null,
    });

    model.send("Second");
    advance(3_000);
    await model.stop();
    const turns = model.getSnapshot().conversations["session-1"].completedTurns;
    expect(turns.map((turn) => turn.duration)).toEqual([1, 3]);
  });

  test("a prompt waiting for its session is timed from the moment it was sent", async () => {
    const transport = new ScriptedTransport();
    let clock = 500;
    const model = new AgentConnectionModel(transport, immediate, () => clock);
    await model.connect(LAUNCH);
    transport.emit(fixture.events.ready);
    model.startNewConversation();
    model.send("Queued before the session exists");
    expect(model.getSnapshot().pendingNewConversationStartedAt).toBe(500);

    clock = 2_000;
    transport.emit({ ...fixture.events.sessionCreated, token: transport.token("newSession") });
    const snapshot = model.getSnapshot();
    expect(snapshot.pendingNewConversationStartedAt).toBeNull();
    expect(snapshot.conversations["session-1"].activeTurn?.startedAt).toBe(500);
  });

  test("usage without the required counters is not shown as zero", () => {
    expect(parseTurnUsage({ inputTokens: 1 })).toBeNull();
    expect(parseTurnUsage({ totalTokens: -1, inputTokens: 1, outputTokens: 1 })).toBeNull();
    expect(parseTurnUsage({ totalTokens: 3, inputTokens: 1, outputTokens: 2 })).toEqual({
      totalTokens: 3,
      inputTokens: 1,
      outputTokens: 2,
      thoughtTokens: null,
      cachedReadTokens: null,
      cachedWriteTokens: null,
    });
  });

  test("durations truncate like macOS and switch units at a minute and an hour", () => {
    const labels = {
      hours: (h: number, m: number, s: number) => `${h}h ${m}m ${s}s`,
      minutes: (m: number, s: number) => `${m}m ${s}s`,
      seconds: (s: number) => `${s}s`,
    };
    expect(formatTurnDuration(59.9, labels)).toBe("59s");
    expect(formatTurnDuration(61, labels)).toBe("1m 1s");
    expect(formatTurnDuration(3723, labels)).toBe("1h 2m 3s");
    expect(formatTurnDuration(Number.POSITIVE_INFINITY, labels)).toBe("—");
  });
});
