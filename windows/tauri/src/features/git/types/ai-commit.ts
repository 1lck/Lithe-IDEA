export const COMMIT_FORMATS = [
  "conventional",
  "concise",
  "imperative",
  "descriptive",
  "releaseNote",
  "custom",
] as const;
export const COMMIT_PROTOCOLS = ["responses", "chatCompletions", "anthropicMessages"] as const;
export const COMMIT_EFFORTS = [
  "default",
  "none",
  "minimal",
  "low",
  "medium",
  "high",
  "xhigh",
  "max",
] as const;
export const CHAT_TOKEN_LIMIT_FIELDS = ["max_completion_tokens", "max_tokens"] as const;

export interface CommitProvider {
  id: string;
  name: string;
  endpoint: string;
  model: string;
  apiProtocol: (typeof COMMIT_PROTOCOLS)[number];
  authentication: "bearer" | "apiKey";
  source: "local" | "codex" | "claude";
  requiresApiKey: boolean;
  allowsInsecureHttp: boolean;
  chatTokenLimitField: (typeof CHAT_TOKEN_LIMIT_FIELDS)[number];
}

export interface CommitOptions {
  language: "english" | "simplifiedChinese";
  format: (typeof COMMIT_FORMATS)[number];
  customInstructions: string;
  includeBody: boolean;
  subjectMaximumLength: number;
  maximumDiffCharacters: number;
  reasoningEffort: (typeof COMMIT_EFFORTS)[number];
}

export interface CommitAISettings extends CommitOptions {
  enabled: boolean;
  providers: CommitProvider[];
  activeProviderId: string | null;
}

export interface DetectedCommitConfiguration {
  provider: CommitProvider;
  hasCredential: boolean;
}
export interface CommitDetection {
  configurations: DetectedCommitConfiguration[];
  warnings: { source: string; code: string }[];
}
export interface CommitFileInput {
  path: string;
  changeKind: string;
  diff: string;
  fingerprint?: string;
}

export const DEFAULT_COMMIT_AI: CommitAISettings = {
  enabled: true,
  providers: [],
  activeProviderId: null,
  language: "english",
  format: "conventional",
  customInstructions: "",
  includeBody: false,
  subjectMaximumLength: 72,
  maximumDiffCharacters: 32_000,
  reasoningEffort: "default",
};

export function newCommitProvider(id: string): CommitProvider {
  return {
    id,
    name: "",
    endpoint: "",
    model: "",
    apiProtocol: "responses",
    authentication: "bearer",
    source: "local",
    requiresApiKey: true,
    allowsInsecureHttp: false,
    chatTokenLimitField: "max_completion_tokens",
  };
}

/** Allowlist persisted fields so imported settings cannot retain credentials or malformed profiles. */
export function normalizeCommitAI(value: unknown): CommitAISettings {
  const v = value && typeof value === "object" ? (value as Record<string, unknown>) : {};
  const text = (value: unknown, limit = 2_048) =>
    typeof value === "string" ? value.slice(0, limit) : "";
  const choice = <T extends string>(value: unknown, choices: readonly T[], fallback: T): T =>
    choices.includes(value as T) ? (value as T) : fallback;
  const number = (value: unknown, min: number, max: number, fallback: number) =>
    typeof value === "number" && Number.isFinite(value)
      ? Math.min(max, Math.max(min, Math.round(value)))
      : fallback;
  const ids = new Set<string>();
  const providers: CommitProvider[] = (Array.isArray(v.providers) ? v.providers : [])
    .slice(0, 30)
    .flatMap((item) => {
      if (
        !item ||
        typeof item !== "object" ||
        typeof item.id !== "string" ||
        !/^[a-zA-Z0-9-]{1,128}$/.test(item.id) ||
        ids.has(item.id)
      )
        return [];
      ids.add(item.id);
      return [
        {
          id: item.id,
          name: text(item.name, 128),
          endpoint: text(item.endpoint),
          model: text(item.model, 512),
          source: choice(item.source, ["local", "codex", "claude"], "local"),
          apiProtocol: choice(item.apiProtocol, COMMIT_PROTOCOLS, "responses"),
          authentication: choice(item.authentication, ["bearer", "apiKey"], "bearer"),
          requiresApiKey: item.requiresApiKey !== false,
          allowsInsecureHttp: item.allowsInsecureHttp === true,
          chatTokenLimitField: choice(
            item.chatTokenLimitField,
            CHAT_TOKEN_LIMIT_FIELDS,
            "max_completion_tokens",
          ),
        },
      ];
    });
  return {
    enabled: v.enabled !== false,
    providers,
    activeProviderId: providers.some((p) => p.id === v.activeProviderId)
      ? (v.activeProviderId as string)
      : (providers[0]?.id ?? null),
    language: choice(v.language, ["english", "simplifiedChinese"], "english"),
    format: choice(v.format, COMMIT_FORMATS, "conventional"),
    customInstructions: text(v.customInstructions, 4_000),
    includeBody: v.includeBody === true,
    reasoningEffort: choice(v.reasoningEffort, COMMIT_EFFORTS, "default"),
    subjectMaximumLength: number(v.subjectMaximumLength, 20, 200, 72),
    maximumDiffCharacters: number(v.maximumDiffCharacters, 8_000, 120_000, 32_000),
  };
}
