import {
  getRelativePath,
  joinPath,
  normalizePath,
  pathStartsWithRoot,
} from "@/utils/path-helpers";
import type { MavenModule, MavenProject } from "../types/maven.types";
import type { CoreJavaTestMethod } from "../api/maven-core-api";

export interface MavenTestTarget {
  className: string;
  module: string | null;
}

export function normalizeMavenTestMethod(method: string): string | null {
  const normalized = method.trim().replace(/\(\)$/, "");
  return /^[A-Za-z_$][A-Za-z0-9_$]*$/.test(normalized) ? normalized : null;
}

export function createMavenTestSelector(className: string, method?: string): string | null {
  if (!/^[A-Za-z_$][A-Za-z0-9_$.]*$/.test(className)) return null;
  if (method === undefined) return className;
  const normalizedMethod = normalizeMavenTestMethod(method);
  return normalizedMethod ? `${className}#${normalizedMethod}` : null;
}

function flattenModules(project: MavenProject): MavenModule[] {
  const modules: MavenModule[] = [
    {
      relativePath: ".",
      groupId: project.groupId,
      artifactId: project.artifactId,
      version: project.version,
      packaging: project.packaging,
      sourceRoots: project.sourceRoots,
      modules: project.modules,
    },
  ];
  const visit = (children: readonly MavenModule[]) => {
    for (const module of children) {
      modules.push(module);
      visit(module.modules);
    }
  };
  visit(project.modules);
  return modules;
}

function moduleRoot(root: string, reactorPath: string, modulePath: string): string {
  const reactorRoot = joinPath(root, reactorPath === "." ? "" : reactorPath);
  return joinPath(reactorRoot, modulePath === "." ? "" : modulePath);
}

function sourceRootForFile(
  filePath: string,
  rootPath: string,
  reactorPath: string,
  module: MavenModule,
): { root: string; relative: string } | null {
  const modulePath = moduleRoot(rootPath, reactorPath, module.relativePath);
  if (!pathStartsWithRoot(filePath, modulePath)) return null;
  const moduleRelative = getRelativePath(filePath, modulePath);
  const candidates = module.sourceRoots
    .filter((sourceRoot) => sourceRoot.kind === "mainJava" || sourceRoot.kind === "testJava")
    .map((sourceRoot) => ({
      sourceRoot,
      path: normalizePath(sourceRoot.path).replace(/^\/+|\/+$/g, ""),
    }))
    .filter(({ path }) => moduleRelative === path || moduleRelative.startsWith(`${path}/`))
    .sort((left, right) => right.path.length - left.path.length);
  const candidate = candidates[0];
  if (!candidate) return null;
  const relative = moduleRelative.slice(candidate.path.length).replace(/^\/+/, "");
  return { root: modulePath, relative };
}

function conventionalSourceRoot(
  relativePath: string,
): { marker: string; module: string | null } | null {
  const normalized = normalizePath(relativePath).replace(/^\/+/, "");
  const match = normalized.match(/^(.*?)(?:src\/(?:test|main)\/java)\/(.+)$/);
  if (!match) return null;
  const module = match[1].replace(/\/$/, "");
  return {
    marker: match[0].slice(0, match[0].length - match[2].length),
    module: module || null,
  };
}

function pathRelativeToReactor(
  filePath: string,
  rootPath: string,
  reactorPath: string,
): string | null {
  const workspaceRelative = normalizePath(getRelativePath(filePath, rootPath)).replace(/^\/+/, "");
  const normalizedReactor = normalizePath(reactorPath).replace(/^\/+|\/+$/g, "");
  if (!normalizedReactor || normalizedReactor === ".") return workspaceRelative;
  if (workspaceRelative === normalizedReactor) return "";
  if (!workspaceRelative.startsWith(`${normalizedReactor}/`)) return null;
  return workspaceRelative.slice(normalizedReactor.length + 1);
}

export function resolveMavenTestTarget(
  filePath: string,
  rootPath: string,
  project: MavenProject,
  requestedModule?: string | null,
): MavenTestTarget | null {
  const normalizedFilePath = normalizePath(filePath);
  const modules = flattenModules(project);
  const matchingModules = requestedModule
    ? modules.filter((module) => module.relativePath === requestedModule)
    : modules;
  const sourceMatches = matchingModules
    .map((module) => {
      const match = sourceRootForFile(normalizedFilePath, rootPath, project.relativePath, module);
      return match ? { module, match } : null;
    })
    .filter((value): value is { module: MavenModule; match: { root: string; relative: string } } => !!value)
    .sort((left, right) => right.match.root.length - left.match.root.length);
  const sourceMatch = sourceMatches[0];
  let relative = sourceMatch?.match.relative;
  let modulePath: string | null = sourceMatch?.module.relativePath ?? (requestedModule || null);

  if (!relative) {
    const reactorRelativePath = pathRelativeToReactor(
      normalizedFilePath,
      rootPath,
      project.relativePath,
    );
    if (reactorRelativePath === null) return null;
    const fallback = conventionalSourceRoot(reactorRelativePath);
    if (!fallback) return null;
    relative = reactorRelativePath.slice(fallback.marker.length);
    modulePath = requestedModule || fallback.module;
  }

  if (!relative.toLowerCase().endsWith(".java")) return null;
  const className = relative
    .replace(/\\/g, "/")
    .replace(/\.java$/i, "")
    .split("/")
    .filter(Boolean)
    .join(".");
  return createMavenTestSelector(className)
    ? { className, module: modulePath === "." ? null : modulePath }
    : null;
}

export interface JavaTestMethod {
  name: string;
  line: number;
  endLine: number;
}

export function projectJavaTestMethods(methods: readonly CoreJavaTestMethod[]): JavaTestMethod[] {
  const projected: JavaTestMethod[] = [];
  const names = new Set<string>();
  for (const method of methods) {
    if (
      !/^[A-Za-z_$][A-Za-z0-9_$]*$/.test(method.name) ||
      !Number.isInteger(method.line) ||
      !Number.isInteger(method.endLine) ||
      method.line <= 0 ||
      method.endLine < method.line ||
      names.has(method.name)
    ) {
      continue;
    }
    names.add(method.name);
    projected.push({
      name: method.name,
      line: method.line - 1,
      endLine: method.endLine - 1,
    });
  }
  return projected;
}

export function javaTestMethodAtLine(
  methods: readonly JavaTestMethod[],
  line: number,
): JavaTestMethod | null {
  for (let index = methods.length - 1; index >= 0; index -= 1) {
    const method = methods[index]!;
    if (method.line > line) continue;
    if (line <= method.endLine) return method;
  }
  return null;
}
