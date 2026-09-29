import { describe, expect, test } from "bun:test";
import { createConversation, appendMessage, type AgentSessionSummary } from "../types/agent.types";
import type { AgentHistoryMetadataMap } from "../types/agent-history.types";
import {
  agentHistoryKey,
  markAgentHistory,
  parseAgentHistoryMetadata,
  renameAgentHistoryEntry,
} from "./agent-history-annotations";
import { agentHistoryRows, historyDate, historyMessageCount } from "./agent-history-view";

function session(id: string, title: string | null, updatedAt: string | null): AgentSessionSummary {
  return { id, title, updatedAt };
}

const sessions: AgentSessionSummary[] = [
  session("session-old", "Rename the parser", "2026-09-20T08:00:00Z"),
  session("session-new", "Beta", "2026-09-27T08:00:00.250Z"),
  session("session-none", null, null),
];

describe("History scope key", () => {
  test("normalises Windows separators and a trailing slash", () => {
    expect(agentHistoryKey("D:\\Work\\Lithe\\", "codex-acp")).toBe(
      "codex-acp|D:/Work/Lithe",
    );
    expect(agentHistoryKey("D:/Work/Lithe", "codex-acp")).toBe("codex-acp|D:/Work/Lithe");
  });

  test("one workspace and Agent pair never shares another project's annotations", () => {
    expect(agentHistoryKey("D:\\A", "codex-acp")).not.toBe(agentHistoryKey("D:\\B", "codex-acp"));
    expect(agentHistoryKey("D:\\A", "codex-acp")).not.toBe(agentHistoryKey("D:\\A", "claude-acp"));
  });
});

describe("History metadata", () => {
  test("reads the documented shape and drops everything else", () => {
    expect(
      parseAgentHistoryMetadata({
        kept: { title: "  Pinned  ", isFavorite: true, isHidden: false },
        blankTitle: { title: "   ", isFavorite: "yes", isHidden: null },
        dropped: 42,
      }),
    ).toEqual({
      kept: { title: "Pinned", isFavorite: true, isHidden: false },
      blankTitle: { title: null, isFavorite: false, isHidden: false },
    });
  });

  test("a value that is not an annotation map reads as empty", () => {
    expect(parseAgentHistoryMetadata(null)).toEqual({});
    expect(parseAgentHistoryMetadata(["nope"])).toEqual({});
  });

  test("a blank rename is rejected instead of stored", () => {
    expect(renameAgentHistoryEntry({}, "session-new", "   ")).toBeNull();
    expect(renameAgentHistoryEntry({}, "session-new", "  Renamed  ")).toEqual({
      "session-new": { title: "Renamed", isFavorite: false, isHidden: false },
    });
  });

  test("renaming keeps the marks and the other sessions untouched", () => {
    const before: AgentHistoryMetadataMap = {
      "session-new": { title: null, isFavorite: true, isHidden: false },
      "session-old": { title: "Kept", isFavorite: false, isHidden: true },
    };
    expect(renameAgentHistoryEntry(before, "session-new", "Renamed")).toEqual({
      "session-new": { title: "Renamed", isFavorite: true, isHidden: false },
      "session-old": { title: "Kept", isFavorite: false, isHidden: true },
    });
    expect(before["session-new"].title).toBeNull();
  });

  test("marks apply to every given session and leave the rest alone", () => {
    const marked = markAgentHistory({}, ["a", "b"], { isFavorite: true });
    expect(marked).toEqual({
      a: { title: null, isFavorite: true, isHidden: false },
      b: { title: null, isFavorite: true, isHidden: false },
    });
    expect(markAgentHistory(marked, ["a"], { isHidden: true })["a"]).toEqual({
      title: null,
      isFavorite: true,
      isHidden: true,
    });
  });
});

describe("History rows", () => {
  test("sorts newest first and keeps undated sessions last", () => {
    expect(agentHistoryRows(sessions, {}, "", "all").map((row) => row.session.id)).toEqual([
      "session-new",
      "session-old",
      "session-none",
    ]);
  });

  test("a date-only or malformed timestamp is not a usable order key", () => {
    expect(historyDate("2026-09-20T08:00:00Z")).toBe(Date.parse("2026-09-20T08:00:00Z"));
    expect(historyDate("2026-09-20")).toBeNull();
    expect(historyDate("yesterday")).toBeNull();
    expect(historyDate(null)).toBeNull();
  });

  test("removed sessions leave the main list and come back under removed", () => {
    const metadata: AgentHistoryMetadataMap = {
      "session-old": { title: null, isFavorite: false, isHidden: true },
    };
    expect(agentHistoryRows(sessions, metadata, "", "all").map((row) => row.session.id)).toEqual([
      "session-new",
      "session-none",
    ]);
    expect(agentHistoryRows(sessions, metadata, "", "removed").map((row) => row.session.id)).toEqual(
      ["session-old"],
    );
  });

  test("favourites are a subset of the main list, never the removed one", () => {
    const metadata: AgentHistoryMetadataMap = {
      "session-old": { title: null, isFavorite: true, isHidden: false },
      "session-new": { title: null, isFavorite: true, isHidden: true },
    };
    expect(
      agentHistoryRows(sessions, metadata, "", "favorites").map((row) => row.session.id),
    ).toEqual(["session-old"]);
  });

  test("a search matches the shown title or the session id", () => {
    const metadata: AgentHistoryMetadataMap = {
      "session-old": { title: "Renamed parser", isFavorite: false, isHidden: false },
    };
    expect(agentHistoryRows(sessions, metadata, "renamed", "all").map((row) => row.session.id)).toEqual(
      ["session-old"],
    );
    expect(agentHistoryRows(sessions, metadata, "parser", "all").map((row) => row.session.id)).toEqual(
      ["session-old"],
    );
    expect(agentHistoryRows(sessions, metadata, "SESSION-NONE", "all").map((row) => row.session.id)).toEqual(
      ["session-none"],
    );
    expect(agentHistoryRows(sessions, metadata, "nothing", "all")).toEqual([]);
  });

  test("a row shows Lithe's title when there is one and the Agent's otherwise", () => {
    const metadata: AgentHistoryMetadataMap = {
      "session-old": { title: "Lithe title", isFavorite: false, isHidden: false },
    };
    expect(agentHistoryRows(sessions, metadata, "", "all")[1].title).toBe("Lithe title");
    expect(agentHistoryRows(sessions, metadata, "", "all")[0].title).toBe("Beta");
    expect(agentHistoryRows(sessions, metadata, "", "all")[2].title).toBeNull();
  });
});

describe("History message count", () => {
  test("counts turns, not tool traffic", () => {
    let conversation = createConversation();
    conversation = appendMessage(conversation, "user", "hi");
    conversation = appendMessage(conversation, "tool", "");
    conversation = appendMessage(conversation, "agent", "hello");
    expect(historyMessageCount(conversation)).toBe(2);
  });

  test("a loading or untouched conversation has no count yet", () => {
    expect(historyMessageCount(null)).toBeNull();
    expect(historyMessageCount({ ...createConversation(), isLoading: true })).toBeNull();
    expect(historyMessageCount(createConversation())).toBeNull();
  });
});
