import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { LocaleProvider } from "@/i18n/locale-provider";
import { installHappyDom } from "@/test-utils/happy-dom";
import { useAgentSurfaceStore } from "../stores/agent-surface.store";
import { createConversation, emptyToolDetails, type AgentConversationMessage } from "../types/agent.types";
import { AgentTranscript } from "./agent-transcript";

const actGlobal = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
let previousActEnvironment: boolean | undefined;
let previousObserver: PropertyDescriptor | undefined;
let restoreDom: () => void;
let root: Root;
let container: HTMLDivElement;

function message(id: string, role: AgentConversationMessage["role"], text: string): AgentConversationMessage {
  return { id, role, text, delivery: null, toolStatus: role === "tool" ? "completed" : null,
    toolDetails: emptyToolDetails() };
}
const messages = [message("u1", "user", "Explain the project"),
  message("r1", "reasoning", "Inspect the manifest"),
  message("a1", "agent", "I will read the project"), message("t1", "tool", "Read README"),
  message("r2", "reasoning", "Check the source layout"), message("a2", "agent", "This is the final answer")];

beforeEach(() => {
  restoreDom = installHappyDom();
  previousActEnvironment = actGlobal.IS_REACT_ACT_ENVIRONMENT;
  actGlobal.IS_REACT_ACT_ENVIRONMENT = true;
  previousObserver = Object.getOwnPropertyDescriptor(globalThis, "IntersectionObserver");
  // Viewport navigation is unrelated to disclosure. This fixture owns no live observer.
  Object.defineProperty(globalThis, "IntersectionObserver", { configurable: true, value: class {
    observe() {}
    disconnect() {}
  } });
  useAgentSurfaceStore.getState().actions.reset();
  container = document.createElement("div");
  document.body.append(container);
  root = createRoot(container);
});
afterEach(async () => {
  try { await act(async () => root.unmount()); }
  finally {
    container.remove();
    useAgentSurfaceStore.getState().actions.reset();
    if (previousObserver) Object.defineProperty(globalThis, "IntersectionObserver", previousObserver);
    else Reflect.deleteProperty(globalThis, "IntersectionObserver");
    restoreDom();
    if (previousActEnvironment === undefined) delete actGlobal.IS_REACT_ACT_ENVIRONMENT;
    else actGlobal.IS_REACT_ACT_ENVIRONMENT = previousActEnvironment;
  }
});

function render(searchText = "", entries = messages, sessionID = "first", isResponding = false) {
  const conversation = { ...createConversation(), messages: entries, isResponding };
  act(() => root.render(<LocaleProvider language="en-US"><AgentTranscript
    conversation={conversation} sessionID={sessionID} agentName="Fixture" agentVersion={null}
    pendingPrompt={null} pendingStartedAt={null} isCreatingSession={false}
    searchText={searchText} now={() => 0} onSwitchAgent={() => {}} onOpenLocation={() => {}}
    onAnswerPermission={() => {}} /></LocaleProvider>));
}
function header(): HTMLButtonElement {
  const button = container.querySelector<HTMLButtonElement>('button[title="Show thinking"], button[title="Hide thinking"]');
  if (!button) throw new Error("Process disclosure missing");
  return button;
}

describe("Agent turn process disclosure", () => {
  test("streaming activity stays collapsed until the user expands it", () => {
    render("", messages.slice(0, 2), "first", true);
    expect(header().getAttribute("aria-expanded")).toBe("false");
    expect(container.textContent).not.toContain("Inspect the manifest");
    render("", messages.slice(0, 5), "first", true);
    expect(header().getAttribute("aria-expanded")).toBe("false");
    act(() => header().click());
    render("", messages, "first", false);
    expect(header().getAttribute("aria-expanded")).toBe("true");
    expect(container.textContent).toContain("This is the final answer");
  });

  test("all intermediate content is hidden behind one header while the reply stays visible", () => {
    render();
    expect(container.textContent).toContain("This is the final answer");
    expect(container.textContent).not.toContain("Inspect the manifest");
    expect(container.textContent).not.toContain("I will read the project");
    expect(container.textContent).not.toContain("Read README");
    expect(header().getAttribute("aria-expanded")).toBe("false");
    act(() => header().click());
    expect(container.textContent).toContain("Inspect the manifest");
    expect(container.textContent).toContain("I will read the project");
    expect(container.textContent).toContain("Read README");
    expect(container.textContent).toContain("Check the source layout");
    expect(container.querySelectorAll('button[title="Hide thinking"]')).toHaveLength(1);
    act(() => header().click());
    expect(container.textContent).not.toContain("Inspect the manifest");
    expect(container.textContent).toContain("This is the final answer");
  });

  test("search temporarily reveals the process without replacing a manual collapse", () => {
    render();
    act(() => header().click());
    act(() => header().click());
    render("manifest");
    expect(container.textContent).toContain("Inspect the manifest");
    act(() => header().click());
    expect(header().getAttribute("aria-expanded")).toBe("true");
    render();
    expect(header().getAttribute("aria-expanded")).toBe("false");
    expect(container.textContent).not.toContain("Inspect the manifest");
  });

  test("expansion follows its session through streamed growth and filtered remounts", () => {
    render("", messages.slice(0, 3));
    act(() => header().click());
    render();
    expect(header().getAttribute("aria-expanded")).toBe("true");
    render("not present");
    expect(container.querySelector('button[title="Hide thinking"]')).toBeNull();
    render("", messages, "second");
    expect(header().getAttribute("aria-expanded")).toBe("false");
    render();
    expect(header().getAttribute("aria-expanded")).toBe("true");
  });
});
