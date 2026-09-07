import { executeCore } from "@/core/lithe-core-client";
import type {
  MavenDependenciesResponse,
  MavenDiagnostic,
  MavenLaunchContext,
  MavenLaunchPlan,
  MavenProject,
} from "../types/maven.types";

let requestSequence = 0;

function nextRequestId(prefix: string): string {
  requestSequence += 1;
  return `${prefix}-${Date.now()}-${requestSequence}`;
}

async function mavenCore<T>(
  command: string,
  payload: unknown,
  timeoutMilliseconds = 30_000,
): Promise<T> {
  const response = await executeCore<T>({
    id: nextRequestId(command),
    operationId: nextRequestId(`${command}-op`),
    timeoutMilliseconds,
    command,
    payload,
  });
  if (!response.ok) {
    const error = new Error(response.error.message) as Error & { code?: string; details?: string };
    error.code = response.error.code;
    error.details = response.error.details;
    throw error;
  }
  return response.data;
}

export function scanMavenProject(root: string, paths: string[] = []) {
  return mavenCore<MavenProject | null>("maven.scan", { root, paths }, 60_000);
}

export function createMavenLaunchPlan(
  root: string,
  context: MavenLaunchContext,
  goals: string[],
  module?: string | null,
) {
  return mavenCore<MavenLaunchPlan>("maven.launchPlan", {
    root,
    context,
    module: module ?? null,
    goals,
  });
}

export function createMavenDependencyPlan(
  root: string,
  context: MavenLaunchContext,
  module?: string | null,
) {
  return mavenCore<MavenLaunchPlan>("maven.dependencyPlan", {
    root,
    context,
    module: module ?? null,
  });
}

export function parseMavenDependencies(modulePath: string, output: string) {
  return mavenCore<MavenDependenciesResponse>("maven.dependencies", { modulePath, output });
}

export async function parseMavenDiagnostics(root: string, output: string) {
  const result = await mavenCore<{ issues: MavenDiagnostic[] }>("maven.diagnostics", {
    root,
    output,
  });
  return result.issues ?? [];
}
