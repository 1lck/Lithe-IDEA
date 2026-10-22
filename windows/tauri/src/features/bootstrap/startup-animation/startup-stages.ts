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
  progress: number;
  labelKey: string;
  labels: { en: string; zhHans: string };
}

export const STARTUP_STAGES: readonly StartupStageDefinition[] = [
  { id: "preparing", order: 1, progress: 10, labelKey: "startup.stage.preparing", labels: { en: "Preparing Lithe", zhHans: "正在准备 Lithe" } },
  { id: "loadingPlugins", order: 2, progress: 30, labelKey: "startup.stage.loadingPlugins", labels: { en: "Loading plugins", zhHans: "正在加载插件" } },
  { id: "initializingLanguageServices", order: 3, progress: 50, labelKey: "startup.stage.initializingLanguageServices", labels: { en: "Initializing language services", zhHans: "正在初始化语言服务" } },
  { id: "openingWorkspace", order: 4, progress: 72, labelKey: "startup.stage.openingWorkspace", labels: { en: "Opening workspace", zhHans: "正在打开工作区" } },
  { id: "restoringSession", order: 5, progress: 88, labelKey: "startup.stage.restoringSession", labels: { en: "Restoring your last session", zhHans: "正在恢复上次会话" } },
];

export const STARTUP_FAILURE_CODES = [
  "pluginLoadFailed",
  "languageServiceInitializationFailed",
  "workspaceOpenFailed",
  "sessionRestoreFailed",
] as const;

export type StartupFailureCode = (typeof STARTUP_FAILURE_CODES)[number];

/** Wording the startup surface shows when a phase failed. */
export const STARTUP_FAILURE_MESSAGES = {
  failureTitle: {
    labelKey: "startup.failure.title",
    labels: { en: "Lithe could not finish starting", zhHans: "Lithe 未能完成启动" },
  },
  failureContinue: {
    labelKey: "startup.failure.continue",
    labels: { en: "Continue", zhHans: "继续" },
  },
} as const;

export function startupStageLabelKey(stage: StartupStageId): string {
  return startupStageDefinition(stage)?.labelKey ?? STARTUP_STAGES[0].labelKey;
}

/** The contract definition of a phase, including the progress it reports. */
export function startupStageDefinition(stage: StartupStageId): StartupStageDefinition | undefined {
  return STARTUP_STAGES.find((entry) => entry.id === stage);
}
