import { invoke } from "@/platform/tauri-core";
import { getRunWindowLabel } from "../utils/run-window-context";
import type {
  GenericRuntime,
  GlobalToolchain,
  JavaRuntime,
  MavenRuntime,
} from "../types/run.types";

export function listJavaSources(root: string) {
  return invoke<string[]>("run_list_java_sources", { root });
}

export function writeRunDocuments(
  root: string,
  documents: Array<{ relativePath: string; contents: string }>,
) {
  return invoke<void>("run_write_documents", { args: { root, documents } });
}

export function writeRunStdin(sessionId: string, input: string) {
  return invoke<void>("run_write_stdin", {
    windowLabel: getRunWindowLabel(),
    sessionId,
    input,
  });
}

export function discoverRunToolchains(root: string, selected?: GlobalToolchain) {
  return invoke<{ java: JavaRuntime[]; maven: MavenRuntime[]; runtimes: GenericRuntime[] }>("run_discover_toolchains", {
    root,
    javaHomePath: selected?.javaHomePath,
    mavenExecutablePath: selected?.mavenExecutablePath,
    runtimeExecutablePaths: selected?.runtimeExecutablePaths,
  });
}

/** Where a resolved toolchain came from; see `run_resolve_toolchains`. */
export type ToolchainSource =
  | "configured"
  | "javaHome"
  | "path"
  | "project"
  | "detected"
  | "mavenWrapper"
  | "projectJdk";

export type ToolchainResolution =
  | { status: "resolved"; path: string; version: string; vendor: string; source: ToolchainSource; warning?: string }
  | { status: "notFound"; message: string | null }
  | { status: "invalid"; message: string };

export interface ResolvedToolchains {
  java: ToolchainResolution;
  maven: ToolchainResolution;
  mavenJava: ToolchainResolution;
}

/**
 * Resolves the project JDK, Maven and Maven JDK exactly as a launch would,
 * without starting anything, so Settings can show what "automatic" picks.
 */
export function resolveRunToolchains(
  root: string,
  selection: { javaHomePath: string; mavenExecutablePath: string; mavenJavaHomePath: string },
) {
  return invoke<ResolvedToolchains>("run_resolve_toolchains", { args: { root, ...selection } });
}

export function resolveRunLaunch(args: {
  root: string;
  executable: { toolchain?: string | null; command?: string | null; tool?: string | null };
  workingDirectory: string;
  javaHomePath?: string;
  mavenExecutablePath?: string;
  mavenJavaHomePath?: string;
  runtimeExecutablePaths?: Record<string, string>;
  environment?: Record<string, unknown>;
}) {
  return invoke<{
    executable: string;
    workingDirectory: string;
    environment: Record<string, string>;
  }>("run_resolve_launch", { args });
}

/**
 * Runs an execution-owned compiler or resource step with bounded native cleanup.
 */
export function executePreLaunchStep(args: {
  sessionId: string;
  executionId: string;
  /** Shown if closing the window would stop this step. */
  title?: string;
  executable: string;
  arguments: string[];
  workingDirectory: string;
  environment: Record<string, string>;
}) {
  return invoke<{ exitCode: number; output: string }>("run_execute_prelaunch", {
    args: { ...args, windowLabel: getRunWindowLabel() },
  });
}

export function startRunProcess(args: {
  sessionId: string;
  executionId?: string;
  /** Shown if closing the window or quitting would stop this process. */
  title?: string;
  /** Work Lithe started for itself; it ends with the window without a question. */
  background?: boolean;
  executable: string;
  arguments: string[];
  workingDirectory: string;
  environment: Record<string, string>;
}) {
  return invoke<void>("run_start_process", {
    args: {
      ...args,
      windowLabel: getRunWindowLabel(),
    },
  });
}

/** A Run session the native host owns, as listed before a window closes or Lithe exits. */
export interface OwnedRunProcess {
  sessionId: string;
  executionId: string | null;
  title: string | null;
  background: boolean;
  preparing: boolean;
}

/** `window` covers the Run sessions of this window, `application` those of every window. */
export type OwnedRunProcessScope = "window" | "application";

function ownedProcessWindow(scope: OwnedRunProcessScope) {
  return scope === "window" ? getRunWindowLabel() : null;
}

/**
 * Lists the Run sessions the native host owns, including Maven goals and the
 * services of projects that were closed while they kept running.
 */
export function listOwnedRunProcesses(scope: OwnedRunProcessScope) {
  return invoke<OwnedRunProcess[]>("run_list_owned_processes", {
    windowLabel: ownedProcessWindow(scope),
  });
}

/** Stops every owned Run session and waits until their process trees are gone. */
export function stopOwnedRunProcesses(scope: OwnedRunProcessScope) {
  return invoke<void>("run_stop_owned_processes", {
    windowLabel: ownedProcessWindow(scope),
  });
}

export function stopRunProcess(sessionId: string, executionId?: string) {
  return invoke<void>("run_stop_process", {
    windowLabel: getRunWindowLabel(),
    sessionId,
    ...(executionId ? { executionId } : {}),
  });
}
