import type { FileIconSemanticKind } from "@/extensions/icon-themes/file-icon-semantics";
import type { FileEntry } from "@/features/file-system/types/app.types";
import {
  getDirName,
  getRelativePath,
  joinPath,
  normalizePath,
  pathStartsWithRoot,
  stripTrailingPathSeparators,
} from "@/utils/path-helpers";

type DirectorySemanticKind = Extract<
  FileIconSemanticKind,
  | "folder.source-root"
  | "folder.test-root"
  | "folder.resources-root"
  | "folder.test-resources-root"
  | "folder.package"
>;

interface StandardMavenRoot {
  path: string;
  kind: Exclude<DirectorySemanticKind, "folder.package">;
  containsPackages: boolean;
}

const JAVA_RESERVED_PACKAGE_SEGMENTS = new Set([
  "abstract",
  "assert",
  "boolean",
  "break",
  "byte",
  "case",
  "catch",
  "char",
  "class",
  "const",
  "continue",
  "default",
  "do",
  "double",
  "else",
  "enum",
  "exports",
  "extends",
  "false",
  "final",
  "finally",
  "float",
  "for",
  "goto",
  "if",
  "implements",
  "import",
  "instanceof",
  "int",
  "interface",
  "long",
  "module",
  "native",
  "new",
  "null",
  "open",
  "opens",
  "package",
  "permits",
  "private",
  "protected",
  "provides",
  "public",
  "record",
  "requires",
  "return",
  "sealed",
  "short",
  "static",
  "strictfp",
  "super",
  "switch",
  "synchronized",
  "this",
  "throw",
  "throws",
  "to",
  "transient",
  "transitive",
  "true",
  "try",
  "uses",
  "var",
  "void",
  "volatile",
  "while",
  "with",
  "yield",
  "_",
]);

function comparablePath(path: string): string {
  const normalized = normalizePath(stripTrailingPathSeparators(path));
  return /^[A-Za-z]:\//.test(normalized) ? normalized.toLowerCase() : normalized;
}

function pathsEqual(left: string, right: string): boolean {
  return comparablePath(left) === comparablePath(right);
}

function isJavaPackagePath(relativePath: string): boolean {
  const segments = normalizePath(relativePath).split("/").filter(Boolean);
  return (
    segments.length > 0 &&
    segments.every(
      (segment) =>
        !JAVA_RESERVED_PACKAGE_SEGMENTS.has(segment) &&
        /^[\p{ID_Start}_$][\p{ID_Continue}$\u200C\u200D]*$/u.test(segment),
    )
  );
}

function collectEntries(entries: readonly FileEntry[], output: FileEntry[]) {
  for (const entry of entries) {
    output.push(entry);
    if (entry.children) collectEntries(entry.children, output);
  }
}

export function buildMavenDirectorySemantics(
  files: readonly FileEntry[],
): ReadonlyMap<string, DirectorySemanticKind> {
  const entries: FileEntry[] = [];
  collectEntries(files, entries);

  const moduleRoots = Array.from(
    new Set(
      entries
        .filter(
          (entry) =>
            !entry.isDir &&
            entry.name.toLowerCase() === "pom.xml" &&
            !entry.path.startsWith("remote://"),
        )
        .map((entry) => getDirName(entry.path)),
    ),
  ).sort((left, right) => comparablePath(right).length - comparablePath(left).length);

  const standardRoots: StandardMavenRoot[] = moduleRoots.flatMap((moduleRoot) => [
    {
      path: joinPath(moduleRoot, "src", "main", "java"),
      kind: "folder.source-root",
      containsPackages: true,
    },
    {
      path: joinPath(moduleRoot, "src", "test", "java"),
      kind: "folder.test-root",
      containsPackages: true,
    },
    {
      path: joinPath(moduleRoot, "src", "main", "resources"),
      kind: "folder.resources-root",
      containsPackages: false,
    },
    {
      path: joinPath(moduleRoot, "src", "test", "resources"),
      kind: "folder.test-resources-root",
      containsPackages: false,
    },
  ]);

  const semantics = new Map<string, DirectorySemanticKind>();
  for (const entry of entries) {
    if (!entry.isDir) continue;

    for (const standardRoot of standardRoots) {
      if (pathsEqual(entry.path, standardRoot.path)) {
        semantics.set(entry.path, standardRoot.kind);
        break;
      }

      if (!standardRoot.containsPackages || !pathStartsWithRoot(entry.path, standardRoot.path)) {
        continue;
      }

      const relativePath = getRelativePath(entry.path, standardRoot.path);
      if (isJavaPackagePath(relativePath)) {
        semantics.set(entry.path, "folder.package");
        break;
      }
    }
  }

  return semantics;
}
