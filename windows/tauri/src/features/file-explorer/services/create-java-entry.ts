import { mkdir, exists } from "@tauri-apps/plugin-fs";
import { saveDocumentFile } from "@/platform/document-files";
import { joinPath } from "@/utils/path-helpers";
import { isJavaPackageName, renderJavaType, type JavaTypeKind } from "../lib/java-source-template";

const fileOperations = {
  exists,
  mkdir: (path: string) => mkdir(path, { recursive: true }),
  create: async (path: string, content: string) => {
    const outcome = await saveDocumentFile(path, content, null);
    if (outcome.status !== "saved") throw new Error("javaEntry.exists");
  },
};

export async function createJavaPackage(
  directory: string,
  name: string,
  operations = fileOperations,
): Promise<string> {
  if (!isJavaPackageName(name)) throw new Error("javaEntry.invalidPackage");
  const destination = joinPath(directory, name.replace(/\./g, "/"));
  if (await operations.exists(destination)) throw new Error("javaEntry.exists");
  await operations.mkdir(destination);
  return destination;
}

export async function createJavaType(
  options: {
    sourceRoot: string;
    packageName: string;
    name: string;
    kind: JavaTypeKind;
    withMain?: boolean;
  },
  operations = fileOperations,
): Promise<string> {
  // Validate all text before creating directories. The native guarded save refuses
  // an existing file even when another writer wins after the preflight check.
  const content = renderJavaType(options.kind, options.name, options.packageName, options.withMain);
  const directory = options.packageName
    ? joinPath(options.sourceRoot, options.packageName.replace(/\./g, "/"))
    : options.sourceRoot;
  const file = options.kind === "packageInfo" ? "package-info.java" : `${options.name}.java`;
  const destination = joinPath(directory, file);
  if (await operations.exists(destination)) throw new Error("javaEntry.exists");
  await operations.mkdir(directory);
  await operations.create(destination, content);
  return destination;
}
