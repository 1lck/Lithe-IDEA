import { agentFileUri } from "../types/agent-file-uri";
import { addFileReferences } from "../types/agent.types";

/** Validate the entire disk batch before changing any conversation or draft. */
export async function validatedAttachmentUris(
  paths: string[],
  isFile: (path: string) => Promise<boolean>,
  isCurrent: () => boolean,
): Promise<string[]> {
  const uris = paths.map(agentFileUri);
  addFileReferences([], uris);
  const available = await Promise.all(paths.map(isFile));
  if (!isCurrent()) throw new Error("agent.context.stale");
  if (available.some((found) => !found)) throw new Error("agent.context.unavailable");
  return uris;
}
