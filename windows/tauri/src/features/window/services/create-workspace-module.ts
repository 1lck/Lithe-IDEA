import { getProjectNameError } from "../lib/new-project-model";
import type { SpringProjectOptions } from "../lib/spring-initializr";

export interface ModuleRequest {
  workspaceRoot: string;
  parentPath: string;
  name: string;
  source: "java" | "spring-boot";
  springOptions?: SpringProjectOptions;
}
export interface ModuleCreationPorts {
  activeRoot: () => string | undefined;
  create: (request: Record<string, unknown>) => Promise<string>;
  attach: (path: string) => Promise<boolean>;
}
/** Creation uses the existing atomic scaffold provider, never edits a parent build model.
 * A successfully created folder is retained if attachment fails or the workspace changes.
 */
export async function createWorkspaceModule(request: ModuleRequest, ports: ModuleCreationPorts) {
  const error = getProjectNameError(request.name);
  if (error) throw new Error(error);
  if (!request.parentPath.trim() || /^(?:remote|wsl):\/\//.test(request.parentPath)) {
    throw new Error("A module needs a local parent directory.");
  }
  if (ports.activeRoot() !== request.workspaceRoot)
    throw new Error("The active workspace changed.");
  if (request.source === "spring-boot" && !request.springOptions)
    throw new Error("Select Spring Boot options first.");
  const path = await ports.create({
    ...(request.source === "spring-boot" ? request.springOptions : {}),
    parentPath: request.parentPath.trim(),
    name: request.name.trim(),
    source: request.source,
  });
  return attachCreatedModule(request.workspaceRoot, path, ports);
}

export async function attachCreatedModule(
  workspaceRoot: string,
  path: string,
  ports: ModuleCreationPorts,
) {
  if (ports.activeRoot() !== workspaceRoot)
    return { path, attached: false, reason: "workspaceChanged" as const };
  try {
    const attached = await ports.attach(path);
    return { path, attached, reason: attached ? null : ("moduleCreated" as const) };
  } catch {
    // Return the created path, rather than encouraging a second create or deleting user files.
    return { path, attached: false, reason: "moduleCreated" as const };
  }
}
