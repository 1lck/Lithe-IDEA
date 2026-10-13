import type { RunConfiguration } from "../types/run.types";
import { runnableConfigurations } from "./run-configuration";

export const RUN_LANGUAGE_TITLES = {
  java: "Java",
  nodejs: "Node.js",
  python: "Python",
  rust: "Rust",
  go: "Go",
  swift: "Swift",
  php: "PHP",
  ruby: "Ruby",
  dotnet: ".NET",
  infrastructure: "",
  tools: "",
  other: "",
} as const;

export type RunLanguageKey = keyof typeof RUN_LANGUAGE_TITLES;

/** Browsing only: provider facts identify ecosystems, never change execution or launch plans. */
export function runConfigurationLanguageKey(
  configuration: Pick<RunConfiguration, "provider" | "category">,
): RunLanguageKey {
  if (configuration.category === "infrastructure") return "infrastructure";
  const namespace = configuration.provider.split(".")[0];
  switch (namespace) {
    case "java":
    case "maven":
    case "gradle":
    case "spring-boot":
    case "quarkus":
    case "micronaut":
      return "java";
    case "npm":
    case "pnpm":
    case "yarn":
    case "bun":
    case "node":
    case "nodejs":
    case "javascript":
    case "typescript":
      // npm metadata does not prove the source language; keep JS/TS in their shared ecosystem.
      return "nodejs";
    case "python":
      return "python";
    case "cargo":
    case "rust":
      return "rust";
    case "go":
    case "swift":
    case "php":
    case "ruby":
      return namespace;
    case "dotnet":
    case "csharp":
    case "fsharp":
      return "dotnet";
    case "docker":
    case "compose":
      return "infrastructure";
    case "make":
    case "just":
    case "procfile":
      return "tools";
    default:
      return "other";
  }
}

export function runConfigurationLanguageGroups(configurations: RunConfiguration[]) {
  const visible = runnableConfigurations(configurations).filter(
    (configuration) => configuration.execution !== "group",
  );
  return (Object.keys(RUN_LANGUAGE_TITLES) as RunLanguageKey[])
    .map((id) => ({
      id,
      configurations: visible.filter(
        (configuration) => runConfigurationLanguageKey(configuration) === id,
      ),
    }))
    .filter((group) => group.configurations.length > 0);
}
