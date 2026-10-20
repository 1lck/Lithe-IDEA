import { describe, expect, test } from "bun:test";
import fixture from "../../../../../../shared/fixtures/agent/acp-events-v1.json";
import {
  addFileReferences,
  AgentFileReferenceError,
  applyCurrentMode,
  AgentFileReferenceLimitError,
  AGENT_FILE_LIMIT,
  appendMessage,
  configOptionLabel,
  createConversation,
  currentPermission,
  enqueuePermission,
  interruptPendingTools,
  isQuotaStale,
  mostUsedQuotaWindow,
  parseAvailableCommands,
  parseContextUsage,
  parsePlan,
  parseSessionConfigOptions,
  planProgress,
  parseSubscriptionQuota,
  permissionPrompt,
  promptDisplayText,
  provisionalTitle,
  stopReasonMessage,
  updateText,
  upsertToolMessage,
} from "./agent.types";

const quotaSnapshot = fixture.events.quota.snapshot;

describe("Available commands", () => {
  test("reads the commands the Agent advertised for the session", () => {
    expect(parseAvailableCommands(fixture.events.availableCommands.update)).toEqual([
      {
        name: "review",
        description: "Review the current changes",
        hint: "optional focus",
      },
      {
        name: "compact",
        description: "Summarize the conversation to free context",
        hint: null,
      },
    ]);
  });

  test("keeps the first definition, drops nameless entries and ignores malformed updates", () => {
    const commands = parseAvailableCommands({
      availableCommands: [
        { name: "review", description: "first" },
        { name: "review", description: "second" },
        { description: "nameless" },
        "not-a-command",
        { name: "", description: "empty" },
      ],
    });
    expect(commands).toEqual([{ name: "review", description: "first", hint: null }]);
    expect(parseAvailableCommands({ availableCommands: "nope" })).toBeNull();
    expect(parseAvailableCommands({})).toBeNull();
  });
});


describe("Agent plan and mode", () => {
  test("reads the plan the agent reported and summarizes its progress", () => {
    const plan = parsePlan(fixture.events.plan.update);
    expect(plan).not.toBeNull();
    expect(plan).toEqual([
      { content: "Read the manifest", priority: "high", status: "completed" },
      { content: "Run the tests", priority: "medium", status: "in_progress" },
      { content: "Summarize the results", priority: "low", status: "pending" },
    ]);
    expect(planProgress(plan ?? [])).toEqual({
      completed: 1,
      total: 3,
      current: "Run the tests",
    });
  });

  test("an empty plan clears but a malformed update leaves it alone", () => {
    expect(parsePlan({ entries: [] })).toEqual([]);
    expect(parsePlan(null)).toBeNull();
    expect(parsePlan({})).toBeNull();
    expect(planProgress([])).toEqual({ completed: 0, total: 0, current: null });
  });

  test("entries without content or with an unknown status are dropped", () => {
    expect(parsePlan({ entries: [{ status: "completed" }] })).toEqual([]);
    expect(
      parsePlan({ entries: [{ content: "Invented", status: "running" }] }),
    ).toEqual([]);
    expect(
      parsePlan({ entries: [{ content: "Kept", status: "pending" }] }),
    ).toEqual([{ content: "Kept", priority: null, status: "pending" }]);
  });

  test("only a mode the agent listed is applied", () => {
    const conversation = {
      ...createConversation(),
      configOptions: parseSessionConfigOptions(
        fixture.events.sessionConfigured.configOptions,
      ),
    };
    const synced = applyCurrentMode(conversation, "auto");
    expect(
      synced.configOptions.find((option) => option.category === "mode")?.currentValue,
    ).toBe("auto");
    expect(applyCurrentMode(conversation, "invented")).toBe(conversation);
    expect(applyCurrentMode(synced, "auto")).toBe(synced);
  });

  test("an option merely named mode is not the mode selector", () => {
    const conversation = {
      ...createConversation(),
      configOptions: parseSessionConfigOptions(
        fixture.events.sessionConfigured.configOptions,
      ).map((option) =>
        option.category === "mode" ? { ...option, category: "custom" } : option,
      ),
    };
    expect(applyCurrentMode(conversation, "auto")).toBe(conversation);
  });
});
describe("Agent context usage", () => {
  test("reads the occupancy the agent reported", () => {
    const usage = parseContextUsage(fixture.events.usageUpdate.update);
    expect(usage).toEqual({ usedTokens: 18700, capacityTokens: 258400, fraction: 18700 / 258400 });
  });

  test("a window without a positive size is unknown rather than zero", () => {
    expect(parseContextUsage({ used: 10, size: 0 })).toBeNull();
    expect(parseContextUsage({ used: 10 })).toBeNull();
  });

  test("occupancy above the window is preserved instead of clamped", () => {
    expect(parseContextUsage({ used: 300, size: 100 })?.fraction).toBeCloseTo(3);
  });
});

describe("Subscription quota", () => {
  test("parses the account windows from the shared fixture", () => {
    const quota = parseSubscriptionQuota(quotaSnapshot);
    expect(quota?.windows).toEqual([
      {
        id: "codex:primary",
        name: "codex",
        limitSeconds: 18000,
        usedPercent: 68,
        resetsAt: 1800003600,
      },
    ]);
    expect(mostUsedQuotaWindow(quota!)?.usedPercent).toBe(68);
  });

  test("rejects a snapshot that cannot be shown as usage", () => {
    expect(parseSubscriptionQuota({ windows: [], fetchedAt: 1 })).toBeNull();
    expect(
      parseSubscriptionQuota({
        windows: [{ id: "a", name: "a", limitSeconds: 0, usedPercent: 1, resetsAt: null }],
        fetchedAt: 1,
      }),
    ).toBeNull();
    expect(
      parseSubscriptionQuota({
        windows: [{ id: "a", name: "a", limitSeconds: 60, usedPercent: 101, resetsAt: null }],
        fetchedAt: 1,
      }),
    ).toBeNull();
    expect(
      parseSubscriptionQuota({
        windows: [{ id: "a", name: "a", limitSeconds: 60, usedPercent: null, resetsAt: null }],
      }),
    ).toBeNull();
  });

  test("an old snapshot or a reset window is stale", () => {
    const quota = parseSubscriptionQuota(quotaSnapshot)!;
    expect(isQuotaStale(quota, quota.fetchedAt + 60)).toBe(false);
    expect(isQuotaStale(quota, quota.fetchedAt + 121)).toBe(true);
    const resetsAt = quotaSnapshot.windows[0].resetsAt;
    if (resetsAt === null) throw new Error("the fixture must carry a reset time");
    expect(isQuotaStale(quota, resetsAt + 1)).toBe(true);
  });
});

describe("Session configuration", () => {
  test("parses the select options the agent reported", () => {
    const options = parseSessionConfigOptions(fixture.events.sessionConfigured.configOptions);
    expect(options.map((option) => option.id)).toEqual(["model", "mode", "reasoning_effort"]);
    expect(configOptionLabel(options[0])).toBe("Example Model");
    expect(options[0].choices).toEqual([
      { id: "example-model", name: "Example Model", group: null, description: null },
    ]);
  });

  test("keeps one level of grouping and ignores other widget types", () => {
    const options = parseSessionConfigOptions([
      {
        id: "model",
        name: "Model",
        type: "select",
        currentValue: "b",
        options: [
          {
            name: "Fast",
            options: [
              { value: "a", name: "A" },
              { value: "b", name: "B" },
            ],
          },
          { value: "c", name: "C" },
        ],
      },
      { id: "text", name: "Text", type: "text", currentValue: "" },
    ]);
    expect(options).toHaveLength(1);
    expect(options[0].choices).toEqual([
      { id: "a", name: "A", group: "Fast", description: null },
      { id: "b", name: "B", group: "Fast", description: null },
      { id: "c", name: "C", group: null, description: null },
    ]);
  });
});

describe("Transcript reduction", () => {
  test("consecutive chunks of one role extend the same message", () => {
    const once = appendMessage(createConversation(), "agent", "This project ");
    const twice = appendMessage(once, "agent", "**builds** an IDE.");
    expect(twice.messages).toHaveLength(1);
    expect(twice.messages[0].text).toBe(fixture.events.agentMessageChunk.update.content.text);
  });

  test("a tool call keeps its identity while partial updates replace present fields", () => {
    const started = upsertToolMessage(
      createConversation(),
      "call-1",
      fixture.events.toolCall.update,
    );
    expect(started.messages[0].id).toBe("tool:call-1");
    expect(started.messages[0].toolStatus).toBe("pending");
    expect(started.messages[0].toolDetails.input).toContain("node --test");
    expect(started.messages[0].toolDetails.locations).toEqual([{ path: "src/main.js", line: 1 }]);

    const finished = upsertToolMessage(started, "call-1", fixture.events.toolCallUpdate.update);
    expect(finished.messages).toHaveLength(1);
    expect(finished.messages[0].toolStatus).toBe("completed");
    expect(finished.messages[0].text).toBe("Run tests");
    expect(finished.messages[0].toolDetails.output).toContain("exitCode");
    expect(finished.messages[0].toolDetails.locations).toEqual([{ path: "src/main.js", line: 1 }]);
  });

  test("a turn that ends without a tool status interrupts it instead of leaving it running", () => {
    const started = upsertToolMessage(
      createConversation(),
      "call-1",
      fixture.events.toolCall.update,
    );
    expect(interruptPendingTools(started).messages[0].toolStatus).toBe("interrupted");
  });

  test("only text content contributes message text", () => {
    expect(updateText(fixture.events.userMessageChunk.update)).toBe("Explain this project");
    expect(updateText({ content: { type: "image" } })).toBeNull();
  });
});

describe("Permission prompts", () => {
  test("reuses the evidence already shown for the tool call", () => {
    const withTool = upsertToolMessage(
      createConversation(),
      "call-1",
      fixture.events.toolCall.update,
    );
    const prompt = permissionPrompt(withTool, "permission-1", fixture.events.permission.request);
    expect(prompt.title).toBe("Run tests");
    expect(prompt.choices.map((choice) => choice.id)).toEqual(["allow_once", "reject_once"]);
    expect(prompt.details.input).toContain("node --test");
  });

  test("the queue keeps both prompts and answers the oldest first", () => {
    const first = permissionPrompt(
      createConversation(),
      "permission-1",
      fixture.events.permission.request,
    );
    const second = permissionPrompt(
      createConversation(),
      "permission-2",
      fixture.events.permission.request,
    );
    const queued = enqueuePermission(enqueuePermission(createConversation(), first), second);
    expect(currentPermission(queued)?.id).toBe("permission-1");
    const replaced = enqueuePermission(queued, { ...first, title: "Updated" });
    expect(replaced.pendingPermissions).toHaveLength(2);
    expect(replaced.pendingPermissions[0].title).toBe("Updated");
  });
});

describe("Prompts and titles", () => {
  test("attached files are shown next to the text, never merged into it", () => {
    const files = addFileReferences([], [fixture.commands.promptWithFiles.files[0].uri]);
    expect(promptDisplayText({ text: "Explain these files", files, submittedAt: 0 })).toBe(
      "Explain these files\n\n📎 file:///example/project/Hello%20World.swift",
    );
  });

  test("only local file URLs are accepted, duplicates collapse, and the draft stays bounded", () => {
    expect(() => addFileReferences([], ["https://example.test/a.md"])).toThrow(
      AgentFileReferenceError,
    );
    const once = addFileReferences([], [fixture.commands.promptWithFiles.files[0].uri]);
    expect(addFileReferences(once, [fixture.commands.promptWithFiles.files[0].uri])).toHaveLength(
      1,
    );
    const allowed = Array.from(
      { length: AGENT_FILE_LIMIT },
      (_, index) => `file:///example/${index}.md`,
    );
    expect(addFileReferences([], allowed)).toHaveLength(AGENT_FILE_LIMIT);
    const tooMany = [...allowed, `file:///example/${AGENT_FILE_LIMIT}.md`];
    expect(() => addFileReferences([], tooMany)).toThrow(/32 files/);
    // The composer translates this typed error, so the limit must travel with it.
    expect(() => addFileReferences([], tooMany)).toThrow(AgentFileReferenceLimitError);
  });

  test("a provisional title is the first line, bounded", () => {
    expect(provisionalTitle("Explain this project\n\nmore")).toBe("Explain this project");
    expect(provisionalTitle("x".repeat(80))).toHaveLength(61);
  });

  test("an early stop explains itself, a normal end does not", () => {
    expect(stopReasonMessage("end_turn")).toBeNull();
    expect(stopReasonMessage("cancelled")).toContain("cancelled");
    expect(stopReasonMessage("something_new")).toContain("something_new");
  });
});
