import { applyRightToolWindowIntent } from "@/features/layout/actions/right-tool-window-actions";

const MAVEN_TOOL_WINDOW_VIEW = "maven";

export function closeMavenToolWindow(): void {
  applyRightToolWindowIntent(MAVEN_TOOL_WINDOW_VIEW, "close");
}

export function toggleMavenToolWindow(): void {
  applyRightToolWindowIntent(MAVEN_TOOL_WINDOW_VIEW, "toggle");
}
