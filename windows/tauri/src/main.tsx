import { createRoot } from "react-dom/client";
import "./styles.css";
import App from "./App.tsx";
import { recordStartupMilestone } from "./features/bootstrap/startup-performance.ts";
import { initializeFrontendTerminalSession } from "./features/terminal/utils/frontend-terminal-session.ts";
import { traceWindowOpen } from "./features/window/utils/window-open-diagnostics.ts";
import { coreRulesInitFailureMessage, initializeCoreRules } from "./core/core-rules.ts";
import { initializeFrontendLogging } from "./features/logging/frontend-log-runtime.ts";

void initializeFrontendLogging();

if (import.meta.env.VITE_REACT_SCAN === "true") {
  void import("react-scan").then(({ scan }) => scan({ enabled: true }));
}

traceWindowOpen("frontend:entry");
recordStartupMilestone("frontend:entry");

const renderStartedAt = performance.now();
traceWindowOpen("reactRender:start");

function showStartupFailure(message: string) {
  const root = document.getElementById("root")!;
  const notice = document.createElement("pre");
  notice.setAttribute("role", "alert");
  notice.style.cssText = "white-space:pre-wrap;padding:24px;font:14px system-ui,sans-serif";
  notice.textContent = message;
  root.replaceChildren(notice);
}

// Rules that run on synchronous hot paths live in wasm. Chromium only compiles modules larger
// than 4 KB asynchronously, so load it first; the UI must not render without it.
const coreRulesReady = initializeCoreRules();

void initializeFrontendTerminalSession()
  .catch((error) => {
    console.warn("Failed to clean up stale terminal sessions:", error);
  })
  .then(() => coreRulesReady)
  .then(
    () => {
    createRoot(document.getElementById("root")!).render(<App />);
    traceWindowOpen("reactRender:scheduled", {
      durationMs: Math.round((performance.now() - renderStartedAt) * 100) / 100,
    });
    recordStartupMilestone("react:scheduled");
    },
    // Only the rules load can reject here; a render error is not a rules failure.
    (error) => showStartupFailure(coreRulesInitFailureMessage(error)),
  );
