import type { ToolchainResolution } from "../api/run-host-api";
import type { RunDiagnostic } from "../types/run.types";

/** How the field reached its value, shown before the resolved toolchain. */
export type EffectiveToolchainMode = "automatic" | "inherit" | "projectJdk" | "configured";

export type EffectiveToolchainState =
  | { status: "detecting" }
  | { status: "failed"; message: string }
  | ToolchainResolution;

export interface EffectiveToolchainLine {
  text: string;
  tone: "normal" | "error";
}

type Translate = (key: string, values?: Record<string, string | number>) => string;

/**
 * Describes the toolchain a launch would use in place of "automatic" or
 * "inherited", for example `Automatic → JDK 21.0.4 · C:\jdk-21 · from JAVA_HOME`.
 */
export function describeEffectiveToolchain(
  state: EffectiveToolchainState,
  kind: "java" | "maven",
  mode: EffectiveToolchainMode,
  t: Translate,
): EffectiveToolchainLine {
  switch (state.status) {
    case "detecting":
      return { text: t("toolchain.detecting"), tone: "normal" };
    case "failed":
      return { text: t("toolchain.failed", { message: state.message }), tone: "error" };
    case "invalid":
      return { text: t("toolchain.invalid", { message: state.message }), tone: "error" };
    case "notFound":
      return {
        text: t(kind === "java" ? "toolchain.javaNotFound" : "toolchain.mavenNotFound"),
        tone: "error",
      };
    case "resolved": {
      const name =
        kind === "java"
          ? state.version
            ? t("toolchain.jdk", { version: state.version })
            : "JDK"
          : state.version
            ? t("toolchain.maven", { version: state.version })
            : "Maven";
      const parts = [name, state.path];
      // A configured value or an inherited project JDK is already named by the mode.
      if (state.source !== "configured" && state.source !== "projectJdk") {
        parts.push(t(`toolchain.source.${state.source}`));
      }
      return { text: `${t(`toolchain.mode.${mode}`)} → ${parts.join(" · ")}`, tone: "normal" };
    }
  }
}

interface ToolchainPaths {
  javaHomePath: string;
  mavenExecutablePath: string;
  mavenJavaHomePath: string;
}

/**
 * The selection one configuration launches with, in the launch's order: its
 * override, then the project default, then the Maven tool window's explicit
 * choice (see `runConfigurationInstance`). Only explicit Maven values count;
 * Maven's resolved installation is what the host picks automatically anyway,
 * and passing it would present an automatic choice as a selected one.
 */
export function launchToolchainSelection(
  override: ToolchainPaths,
  project: ToolchainPaths,
  maven: { mavenExecutablePath: string; javaHomePath: string } | null,
): ToolchainPaths {
  return {
    javaHomePath: override.javaHomePath || project.javaHomePath,
    mavenExecutablePath:
      override.mavenExecutablePath ||
      project.mavenExecutablePath ||
      maven?.mavenExecutablePath ||
      "",
    mavenJavaHomePath:
      override.mavenJavaHomePath || project.mavenJavaHomePath || maven?.javaHomePath || "",
  };
}

const REQUIREMENT_CODES = new Set([
  "missingToolchain",
  "toolchainVersionMismatch",
  "toolchainVendorMismatch",
]);

/**
 * Core's requirement checks for one toolchain, such as a JDK older than the
 * project requires. Without `configurationId`, every configuration's result
 * counts, because project defaults apply to all of them.
 */
export function toolchainRequirementMessages(
  diagnostics: RunDiagnostic[],
  toolchain: "project-jdk" | "project-maven",
  configurationId?: string,
): string[] {
  const messages = diagnostics
    .filter(
      (diagnostic) =>
        REQUIREMENT_CODES.has(diagnostic.code) &&
        diagnostic.toolchain === toolchain &&
        (configurationId === undefined || diagnostic.id === configurationId),
    )
    .map((diagnostic) => diagnostic.message);
  return [...new Set(messages)];
}
