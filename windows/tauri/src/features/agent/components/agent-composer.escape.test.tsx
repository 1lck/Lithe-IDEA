import { afterEach, beforeEach, describe, expect, mock, test } from "bun:test";
import { act, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { LocaleProvider } from "@/i18n/locale-provider";
import { installHappyDom } from "@/test-utils/happy-dom";
import { agentConnection } from "../stores/agent-connection-service";
import type { AgentConversation } from "../types/agent.types";

const cancel = mock(() => {});
const { AgentComposer } = await import("./agent-composer");

const conversation = {
  messages: [],
  contextUsage: null,
  plan: [],
  availableCommands: [{ name: "clear", description: "Clear the conversation", hint: null }],
  activeTurn: null,
  completedTurns: [],
  isResponding: true,
  isLoading: false,
  isCancelling: false,
  configOptions: [],
  pendingConfigToken: null,
  configurationError: null,
  isAttached: true,
  hasCompleteHistory: true,
  pendingPermissions: [],
  errorMessage: null,
} as unknown as AgentConversation;

const actGlobal = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
let previousActEnvironment: boolean | undefined;
let restoreDom: () => void;
let root: Root | undefined;
let container: HTMLDivElement;
let originalCancel: () => void;

function Harness() {
  const [draft, setDraft] = useState("/");
  return (
    <AgentComposer
      conversation={conversation}
      agentName="Codex"
      canSend
      blockedReason=""
      draft={draft}
      onDraftChange={setDraft}
      files={[]}
      onFilesChange={() => {}}
      onOpenSettings={() => {}}
      onError={() => {}}
    />
  );
}

beforeEach(() => {
  restoreDom = installHappyDom();
  previousActEnvironment = actGlobal.IS_REACT_ACT_ENVIRONMENT;
  actGlobal.IS_REACT_ACT_ENVIRONMENT = true;
  cancel.mockClear();
  originalCancel = agentConnection().cancel;
  agentConnection().cancel = cancel;
  container = document.createElement("div");
  document.body.append(container);
  root = createRoot(container);
});

afterEach(async () => {
  try {
    await act(async () => root?.unmount());
  } finally {
    root = undefined;
    container.remove();
    agentConnection().cancel = originalCancel;
    restoreDom();
    if (previousActEnvironment === undefined) delete actGlobal.IS_REACT_ACT_ENVIRONMENT;
    else actGlobal.IS_REACT_ACT_ENVIRONMENT = previousActEnvironment;
  }
});

function pressEscape() {
  const textarea = container.querySelector("textarea");
  if (textarea === null) throw new Error("composer textarea missing");
  act(() => {
    textarea.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
  });
}

describe("Agent composer Escape handling", () => {
  test("the command list consumes the first Escape before the composer cancels", () => {
    act(() => {
      root!.render(
        <LocaleProvider language="en-US">
          <Harness />
        </LocaleProvider>,
      );
    });

    pressEscape();
    expect(cancel).not.toHaveBeenCalled();

    pressEscape();
    expect(cancel).toHaveBeenCalledTimes(1);
  });
});
