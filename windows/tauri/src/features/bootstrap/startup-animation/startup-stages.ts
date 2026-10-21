/**
 * Startup feedback vocabulary shared with the macOS product.
 *
 * The phase ids, their order, the label keys, and the timing thresholds come
 * from `shared/fixtures/settings/startup-feedback-v1.json`. The contract gate
 * (`scripts/verify-startup-feedback-contract.mjs`) compares this file with the
 * shared fixture and with the macOS declaration, so the two products cannot
 * drift apart silently.
 */

/** Startup shorter than this shows no animation and adds no waiting time. */
export const STARTUP_MINIMUM_VISIBLE_DURATION_MS = 400;

/** How long the animation stays on screen after the workbench is ready. */
export const STARTUP_FADE_OUT_DURATION_MS = 180;

export type StartupStageId =
  | "preparing"
  | "loadingPlugins"
  | "initializingLanguageServices"
  | "openingWorkspace"
  | "restoringSession";

export interface StartupStageDefinition {
  id: StartupStageId;
  order: number;
  labelKey: string;
}

export const STARTUP_STAGES: readonly StartupStageDefinition[] = [
  { id: "preparing", order: 1, labelKey: "startup.stage.preparing" },
  { id: "loadingPlugins", order: 2, labelKey: "startup.stage.loadingPlugins" },
  {
    id: "initializingLanguageServices",
    order: 3,
    labelKey: "startup.stage.initializingLanguageServices",
  },
  { id: "openingWorkspace", order: 4, labelKey: "startup.stage.openingWorkspace" },
  { id: "restoringSession", order: 5, labelKey: "startup.stage.restoringSession" },
];

export const STARTUP_FAILURE_CODES = [
  "pluginLoadFailed",
  "languageServiceInitializationFailed",
  "workspaceOpenFailed",
  "sessionRestoreFailed",
] as const;

export type StartupFailureCode = (typeof STARTUP_FAILURE_CODES)[number];

export function startupStageLabelKey(stage: StartupStageId): string {
  return STARTUP_STAGES.find((entry) => entry.id === stage)?.labelKey ?? STARTUP_STAGES[0].labelKey;
}
