import { applyRightToolWindowIntent } from "@/features/layout/actions/right-tool-window-actions";

const AGENT_TOOL_WINDOW_VIEW = "agent";

export function openAgentToolWindow(): void {
  applyRightToolWindowIntent(AGENT_TOOL_WINDOW_VIEW, "open");
}

export function closeAgentToolWindow(): void {
  applyRightToolWindowIntent(AGENT_TOOL_WINDOW_VIEW, "close");
}

export function toggleAgentToolWindow(): void {
  applyRightToolWindowIntent(AGENT_TOOL_WINDOW_VIEW, "toggle");
}
