import type { JavaImplementationMarker } from "./java-navigation-models";
import type { LspDocumentAvailability } from "./lsp-client";
import type { LspDocumentTarget } from "./lsp-document-target";

export interface JavaNavigationMarkerClient {
  ensureDocumentReady(
    target: LspDocumentTarget,
    workspaceRoot: string,
    content: string,
    feature?: string,
  ): Promise<LspDocumentAvailability>;
  getJavaNavigationMarkers(target: LspDocumentTarget): Promise<JavaImplementationMarker[]>;
}

interface LoadJavaNavigationMarkersOptions {
  client: JavaNavigationMarkerClient;
  target: LspDocumentTarget;
  workspaceRoot: string;
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
  workspaceRoot,
  content,
}: LoadJavaNavigationMarkersOptions): Promise<JavaImplementationMarker[]> {
  await client.ensureDocumentReady(target, workspaceRoot, content, "codeLens");
  return client.getJavaNavigationMarkers(target);
}
