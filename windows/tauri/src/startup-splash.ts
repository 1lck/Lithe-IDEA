/**
 * Startup splash window script.
 *
 * The splash is a separate native window that opens while the product boots.
 * It deliberately avoids React and the workbench bundle: the page ships its own
 * markup and styles, so it paints as soon as the window exists instead of
 * waiting for the workbench bundle to download and mount.
 *
 * The shell broadcasts the phase the product is working on; this script turns
 * that phase into the stage wording and the progress value defined by the
 * shared startup contract.
 */

import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { load } from "@tauri-apps/plugin-store";
import {
  STARTUP_FAILURE_MESSAGES,
  STARTUP_STAGES,
  type StartupStageId,
} from "./features/bootstrap/startup-animation/startup-stages";

const APPEARANCE_BOOTSTRAP_CACHE_KEY = "lithe.bootstrap.appearance.v1";
const STARTUP_ANIMATION_BOOTSTRAP_CACHE_KEY = "lithe.bootstrap.startup.v1";

type SplashLanguage = "en" | "zhHans";

const stageElement = document.getElementById("stage") as HTMLElement | null;
const percentElement = document.getElementById("percent") as HTMLElement | null;
const progressElement = document.getElementById("progress") as HTMLElement | null;
const progressFillElement = document.getElementById("progress-fill") as HTMLElement | null;
const failureElement = document.getElementById("failure") as HTMLElement | null;
const failureTitleElement = document.getElementById("failure-title") as HTMLElement | null;
const failureStageElement = document.getElementById("failure-stage") as HTMLElement | null;
const failureReasonElement = document.getElementById("failure-reason") as HTMLElement | null;
const continueElement = document.getElementById("continue") as HTMLButtonElement | null;

let language: SplashLanguage = "zhHans";
let currentStage: StartupStageId = "preparing";
let closed = false;

/** Reads the cached appearance so the splash matches the product theme. */
function applyCachedAppearance(): void {
  try {
    const raw = window.localStorage.getItem(APPEARANCE_BOOTSTRAP_CACHE_KEY);
    if (!raw) return;
    const parsed = JSON.parse(raw) as { themeType?: "light" | "dark" };
    if (parsed.themeType === "light" || parsed.themeType === "dark") {
      document.documentElement.dataset.themeType = parsed.themeType;
    }
  } catch {
    // A missing or broken cache keeps the default appearance.
  }
}

/** Reads the cached switch so a disabled animation closes the splash at once. */
function isAnimationEnabled(): boolean {
  try {
    const raw = window.localStorage.getItem(STARTUP_ANIMATION_BOOTSTRAP_CACHE_KEY);
    if (!raw) return true;
    const parsed = JSON.parse(raw) as { showStartupAnimation?: boolean };
    return parsed.showStartupAnimation !== false;
  } catch {
    return true;
  }
}

/** Resolves the display language from the stored settings. */
async function resolveLanguage(): Promise<SplashLanguage> {
  try {
    const store = await load("settings.json");
    const stored = await store.get<string>("displayLanguage");
    return stored === "en-US" ? "en" : "zhHans";
  } catch {
    return "zhHans";
  }
}

function stageDefinition(stage: StartupStageId) {
  return STARTUP_STAGES.find((entry) => entry.id === stage) ?? STARTUP_STAGES[0];
}

function applyProgress(progress: number): void {
  if (progressFillElement) {
    progressFillElement.style.width = `${progress}%`;
  }
  if (percentElement) {
    percentElement.textContent = `${Math.round(progress)}%`;
  }
  progressElement?.classList.remove("indeterminate");
}

/** Shows the phase the product reported together with its contract progress. */
function applyStage(stage: StartupStageId): void {
  currentStage = stage;
  const definition = stageDefinition(stage);
  if (stageElement) {
    stageElement.textContent = definition.labels[language];
  }
  applyProgress(definition.progress);
}

/** Hands the screen to the workbench. The shell closes this window. */
function completeStartup(): void {
  if (closed) return;
  closed = true;
  void invoke("complete_startup").catch((error) => {
    console.warn("Failed to complete the startup sequence:", error);
  });
}

/**
 * Shows the window once the card is painted.
 *
 * The window is created hidden, because a transparent window that appears
 * before its page painted shows up as an empty frame. Two animation frames
 * guarantee the first paint happened.
 */
function revealSplashWhenPainted(): void {
  window.requestAnimationFrame(() => {
    window.requestAnimationFrame(() => {
      void invoke("reveal_startup_splash").catch((error) => {
        console.warn("Failed to reveal the startup splash:", error);
      });
    });
  });
}

/** Shows the failed phase, the reason and the way back to the workbench. */
function applyFailure(message: string | null): void {
  const definition = stageDefinition(currentStage);
  if (failureTitleElement) {
    failureTitleElement.textContent = STARTUP_FAILURE_MESSAGES.failureTitle.labels[language];
  }
  if (failureStageElement) {
    failureStageElement.textContent = definition.labels[language];
  }
  if (failureReasonElement) {
    failureReasonElement.textContent = message ?? "";
  }
  if (continueElement) {
    continueElement.textContent = STARTUP_FAILURE_MESSAGES.failureContinue.labels[language];
    continueElement.addEventListener("click", () => completeStartup());
  }
  failureElement?.classList.add("visible");
  progressElement?.classList.remove("indeterminate");
}

async function main(): Promise<void> {
  applyCachedAppearance();
  // Paint the first phase right away so the window never shows an empty card.
  applyStage(currentStage);
  revealSplashWhenPainted();

  if (!isAnimationEnabled()) {
    completeStartup();
    return;
  }

  language = await resolveLanguage();
  applyStage(currentStage);

  void listen<string>("lithe://startup-stage", (event) => {
    applyStage(event.payload as StartupStageId);
  });

  void listen<{ message: string | null }>("lithe://startup-failed", (event) => {
    applyFailure(event.payload?.message ?? null);
  });

  void listen("lithe://startup-ready", () => {
    applyProgress(100);
    window.setTimeout(completeStartup, 420);
  });
}

void main();
