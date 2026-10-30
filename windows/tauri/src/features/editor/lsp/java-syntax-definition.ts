import { executeCore } from "@/core/lithe-core-client";
import { readFileContent } from "@/features/file-system/controllers/file-operations";
import { joinPath, normalizePath, pathStartsWithRoot } from "@/utils/path-helpers";
import { importedTypeName } from "./lombok-accessor-navigation";
import type { LspLocation } from "./lsp-client";

interface JavaSourceDefinition {
  line: number;
  utf16Column: number;
}

interface JavaSyntaxDefinitionDependencies {
  listWorkspaceFiles: (root: string) => Promise<string[]>;
  readSource: (filePath: string) => Promise<string>;
  findTypeDefinition: (source: string, typeName: string) => Promise<JavaSourceDefinition | null>;
  findMemberDefinition: (
    source: string,
    typeName: string,
    memberName: string,
    reference: { line: number; utf16Column: number },
  ) => Promise<JavaSourceDefinition | null>;
}

interface ResolveJavaSyntaxDefinitionsOptions {
  source: string;
  sourceFilePath: string;
  workspaceRoot: string;
  line: number;
  character: number;
}

/** A name in many modules is offered as a list, and only this much of it is read. */
const MAX_TYPE_CANDIDATES = 12;

async function sourceDefinition(payload: Record<string, unknown>): Promise<JavaSourceDefinition | null> {
  const response = await executeCore<JavaSourceDefinition | null>({
    id: crypto.randomUUID(),
    command: "java.sourceDefinition",
    payload,
  });
  if (response.ok) return response.data;
  throw new Error(`${response.error.code}: ${response.error.message}`);
}

const defaultDependencies: JavaSyntaxDefinitionDependencies = {
  async listWorkspaceFiles(root) {
    const response = await executeCore<{ files: string[] }>({
      id: crypto.randomUUID(),
      command: "workspace.snapshot",
      payload: { root },
    });
    if (response.ok) return response.data.files;
    throw new Error(`${response.error.code}: ${response.error.message}`);
  },
  readSource: readFileContent,
  findTypeDefinition: (source, declarationName) => sourceDefinition({ source, declarationName }),
  findMemberDefinition: (source, declarationName, memberName, reference) =>
    sourceDefinition({ source, declarationName, memberName, declarationsOnly: true, reference }),
};

function identifierAt(line: string, character: number) {
  for (const match of line.matchAll(/[\p{L}_$][\p{L}\p{N}_$]*/gu)) {
    const end = match.index + match[0].length;
    if (match.index <= character && character <= end) {
      return { name: match[0], start: match.index, end };
    }
  }
  return null;
}

function location(filePath: string, definition: JavaSourceDefinition): LspLocation {
  const position = { line: definition.line, character: definition.utf16Column };
  return { uri: filePath, filePath, range: { start: position, end: position } };
}

function typeSourcePaths(source: string, typeName: string, workspaceFiles: string[]): string[] {
  const expectedName = `${typeName}.java`;
  const candidates = workspaceFiles
    .map(normalizePath)
    .filter((path) => path.split("/").pop() === expectedName)
    .sort((left, right) => left.localeCompare(right));
  const qualifiedName = importedTypeName(source, typeName);
  const expectedSuffix = `/${qualifiedName?.replace(/\./g, "/")}.java`;
  const exact = candidates.filter((path) => `/${path}`.endsWith(expectedSuffix));
  return (exact.length > 0 ? exact : candidates).slice(0, MAX_TYPE_CANDIDATES);
}

/**
 * Finds the declarations of the identifier at a position without a language
 * server, for the minutes a Java project spends importing.
 *
 * Core resolves members from the reference's scope and finds nothing when
 * syntax cannot tell: `other.save()` has a receiver of unknown type, an inherited
 * name is invisible, and a local may shadow a field. Local variables are not
 * covered either. Callers must present the result as an approximation, since
 * only JDT LS knows what a name binds to.
 */
export async function resolveJavaSyntaxDefinitions(
  options: ResolveJavaSyntaxDefinitionsOptions,
  dependencies: JavaSyntaxDefinitionDependencies = defaultDependencies,
): Promise<LspLocation[]> {
  const { source, sourceFilePath, workspaceRoot } = options;
  if (!pathStartsWithRoot(sourceFilePath, workspaceRoot)) return [];
  const lineText = source.split(/\r\n|\r|\n/)[options.line] ?? "";
  const identifier = identifierAt(lineText, options.character);
  if (!identifier) return [];
  const isHere = (definition: JavaSourceDefinition) =>
    definition.line === options.line &&
    identifier.start <= definition.utf16Column &&
    definition.utf16Column <= identifier.end;

  if (/^\p{Lu}/u.test(identifier.name)) {
    const nested = await dependencies.findTypeDefinition(source, identifier.name);
    if (nested) return isHere(nested) ? [] : [location(sourceFilePath, nested)];
    const workspaceFiles = await dependencies.listWorkspaceFiles(workspaceRoot);
    const paths = typeSourcePaths(source, identifier.name, workspaceFiles);
    const locations = await Promise.all(
      paths.map(async (path) => {
        const filePath = normalizePath(joinPath(workspaceRoot, path));
        const definition = await dependencies.findTypeDefinition(
          await dependencies.readSource(filePath),
          identifier.name,
        );
        return definition ? location(filePath, definition) : null;
      }),
    );
    return locations.filter((value) => value !== null);
  }

  const typeName = normalizePath(sourceFilePath).split("/").pop()?.replace(/\.java$/, "") ?? "";
  const member = await dependencies.findMemberDefinition(source, typeName, identifier.name, {
    line: options.line,
    utf16Column: identifier.start,
  });
  return member && !isHere(member) ? [location(sourceFilePath, member)] : [];
}
