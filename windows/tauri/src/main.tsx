import { createRoot } from "react-dom/client";
import "./styles.css";
import App from "./App.tsx";
import { beginStartupFeedback } from "./features/bootstrap/startup-animation/startup-feedback.store";
import { recordStartupMilestone } from "./features/bootstrap/startup-performance.ts";
import { initializeFrontendTerminalSession } from "./features/terminal/utils/frontend-terminal-session.ts";
import { traceWindowOpen } from "./features/window/utils/window-open-diagnostics.ts";
import { initializeFrontendLogging } from "./features/logging/frontend-log-runtime.ts";

void initializeFrontendLogging();

if (import.meta.env.VITE_REACT_SCAN === "true") {
  void import("react-scan").then(({ scan }) => scan({ enabled: true }));
}

traceWindowOpen("frontend:entry");
recordStartupMilestone("frontend:entry");

// The startup feedback starts before React mounts so the phase timer covers the
// whole boot instead of only the part that follows the first render.
beginStartupFeedback();

const renderStartedAt = performance.now();
traceWindowOpen("reactRender:start");

createRoot(document.getElementById("root")!).render(<App />);
traceWindowOpen("reactRender:scheduled", {
  durationMs: Math.round((performance.now() - renderStartedAt) * 100) / 100,
});
recordStartupMilestone("react:scheduled");

// Cleaning up stale terminal sessions is not a prerequisite for the first
// frame. Waiting for it before rendering kept the window empty while the
// startup animation was already able to explain what the product was doing.
// Terminal creation still waits for the session to be accepted.
void initializeFrontendTerminalSession().catch((error) => {
  console.warn("Failed to clean up stale terminal sessions:", error);
});
