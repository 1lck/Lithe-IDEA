import { invoke } from "@/platform/tauri-core";
import type { GlobalToolchain, JavaRuntime, MavenRuntime } from "../types/run.types";

export function listJavaSources(root: string) {
  return invoke<string[]>("run_list_java_sources", { root });
}

export function writeGeneratedRunDocuments(args: {
  root: string;
  generated: unknown;
  toolchainRequirements: unknown;
  defaultRunConfiguration?: string;
}) {
  return invoke<void>("run_write_generated", { args });
}

export function writeRunDocument(root: string, relativePath: string, contents: string) {
  return invoke<void>("run_write_document", {
    args: { root, relativePath, contents },
  });
}

export function writeRunStdin(sessionId: string, input: string) {
  return invoke<void>("run_write_stdin", { sessionId, input });
}

export function discoverRunToolchains(root: string, selected?: GlobalToolchain) {
  return invoke<{ java: JavaRuntime[]; maven: MavenRuntime[] }>("run_discover_toolchains", {
    root,
    javaHomePath: selected?.javaHomePath,
    mavenExecutablePath: selected?.mavenExecutablePath,
  });
}

export function resolveRunLaunch(args: {
  root: string;
  executable: { toolchain?: string | null; command?: string | null };
  workingDirectory: string;
  javaHomePath?: string;
  mavenExecutablePath?: string;
  mavenJavaHomePath?: string;
  environment?: Record<string, unknown>;
}) {
  return invoke<{
    executable: string;
    workingDirectory: string;
    environment: Record<string, string>;
  }>("run_resolve_launch", { args });
}

export function startRunProcess(args: {
  sessionId: string;
  executable: string;
  arguments: string[];
  workingDirectory: string;
  environment: Record<string, string>;
}) {
  return invoke<void>("run_start_process", { args });
}

export function stopRunProcess(sessionId: string) {
  return invoke<void>("run_stop_process", { sessionId });
}
