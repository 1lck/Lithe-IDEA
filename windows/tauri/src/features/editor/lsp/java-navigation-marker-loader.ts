import type { JavaImplementationMarker } from "./java-navigation-models";
import type { LspDocumentAvailability } from "./lsp-client";
import type { LspDocumentTarget } from "./lsp-document-target";
import type { WorkspaceLaunchScope } from "@/features/workspace/types/workspace-launch-scope";

export interface JavaNavigationMarkerClient {
  ensureDocumentReady(
    target: LspDocumentTarget,
    scope: WorkspaceLaunchScope,
    content: string,
    feature?: string,
  ): Promise<LspDocumentAvailability>;
  getJavaNavigationMarkers(target: LspDocumentTarget): Promise<JavaImplementationMarker[]>;
}

interface LoadJavaNavigationMarkersOptions {
  client: JavaNavigationMarkerClient;
  target: LspDocumentTarget;
  workspaceScope: WorkspaceLaunchScope;
  content: string;
}

/**
 * Attaches and opens the physical editor document before requesting Java
 * navigation markers. The LSP client de-duplicates concurrent starts, while
 * virtual documents retain their existing source-session attachment.
 */
export async function loadJavaNavigationMarkers({
  client,
  target,
  workspaceScope,
  content,
}: LoadJavaNavigationMarkersOptions): Promise<JavaImplementationMarker[]> {
  await client.ensureDocumentReady(target, workspaceScope, content, "codeLens");
  return client.getJavaNavigationMarkers(target);
}
