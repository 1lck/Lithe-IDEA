import { openMavenRunPane } from "@/features/maven/actions/maven-tool-window-actions";
import { runMavenTestAction } from "@/features/maven/services/maven-test-actions";
import { editJavaMainConfiguration, runJavaMainFromEditor } from "./java-main-launch";
import type { JavaRunMarker } from "./java-run-markers";

/** Runs what a gutter marker points at: a `main` configuration or a Maven test. */
export async function runJavaRunMarker(
  marker: JavaRunMarker,
  filePath: string,
  workspaceId: string,
): Promise<void> {
  if (marker.kind === "main") {
    if (!marker.mainClass) return;
    await runJavaMainFromEditor(workspaceId, filePath, marker.mainClass);
    return;
  }
  openMavenRunPane();
  await runMavenTestAction(
    filePath,
    marker.kind === "testMethod" ? marker.testMethod : undefined,
    workspaceId,
    marker.testClass,
  );
}

/** Whether a marker has a configuration the user can open and edit. */
export function canEditJavaRunMarkerConfiguration(marker: JavaRunMarker): boolean {
  return marker.kind === "main" && Boolean(marker.mainClass);
}

export async function editJavaRunMarkerConfiguration(
  marker: JavaRunMarker,
  filePath: string,
  workspaceId: string,
): Promise<void> {
  if (!canEditJavaRunMarkerConfiguration(marker) || !marker.mainClass) return;
  await editJavaMainConfiguration(workspaceId, filePath, marker.mainClass);
}

type RunAtCaret = () => boolean;

let activeRunAtCaret: { owner: object; run: RunAtCaret } | null = null;

/**
 * Lets the focused editor answer "Run context configuration". Only one editor
 * surface is active at a time; the returned function unregisters it without
 * clearing a newer registration.
 */
export function registerJavaRunContext(owner: object, run: RunAtCaret): () => void {
  activeRunAtCaret = { owner, run };
  return () => {
    if (activeRunAtCaret?.owner === owner) activeRunAtCaret = null;
  };
}

/** Runs the marker under the focused editor's caret; false when there is none. */
export function runJavaContextConfiguration(): boolean {
  return activeRunAtCaret?.run() ?? false;
}
