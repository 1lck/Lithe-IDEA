import { describe, expect, mock, test } from "bun:test";
import { resolveJavaSyntaxDefinitions } from "./java-syntax-definition";

const root = "C:/work/orders";
const sourceFilePath = `${root}/src/main/java/com/acme/web/OrderController.java`;
const source = `package com.acme.web;
import com.acme.service.OrderService;
class OrderController {
  OrderService service;
  Helper helper;
  void list() { service.save(); audit(); this.audit(); int count = 0; }
  void audit() {}
}
class Helper {}`;

function dependencies(files: string[], typeSources: Record<string, string> = {}) {
  const definitionIn = (text: string, expression: RegExp, token: string) => {
    const lines = text.split("\n");
    const line = lines.findIndex((value) => expression.test(value));
    return line < 0 ? null : { line, utf16Column: lines[line].indexOf(token) };
  };
  return {
    listWorkspaceFiles: mock(async () => files),
    readSource: mock(async (path: string) => typeSources[path] ?? ""),
    findTypeDefinition: mock(async (text: string, typeName: string) =>
      definitionIn(text, new RegExp(`\\b(?:class|interface|enum|record)\\s+${typeName}\\b`), typeName)),
    findMemberDefinition: mock(async (
      text: string,
      _typeName: string,
      memberName: string,
      _reference: { line: number; utf16Column: number },
    ) =>
      definitionIn(text, new RegExp(`^\\s*(?:void|int|\\w+)\\s+${memberName}\\b`), memberName)),
  };
}

function at(line: number, word: string, occurrence = 0) {
  const text = source.split("\n")[line];
  let character = text.indexOf(word);
  for (let index = 0; index < occurrence; index += 1) character = text.indexOf(word, character + 1);
  return { source, sourceFilePath, workspaceRoot: root, line, character: character + 1 };
}

describe("Java syntax definitions", () => {
  test("prefers the imported type among same-named files", async () => {
    const path = "src/main/java/com/acme/service/OrderService.java";
    const deps = dependencies(
      [path, "other/src/main/java/com/legacy/OrderService.java"],
      { [`${root}/${path}`]: "package com.acme.service;\n\npublic class OrderService {}" },
    );
    const locations = await resolveJavaSyntaxDefinitions(at(3, "OrderService"), deps);
    expect(locations).toHaveLength(1);
    expect(locations[0].filePath).toBe(`${root}/${path}`);
    expect(locations[0].range.start).toEqual({ line: 2, character: 13 });
  });

  test("offers every file of a name it cannot place", async () => {
    const first = "a/Missing.java";
    const second = "b/Missing.java";
    const deps = dependencies([first, second], {
      [`${root}/${first}`]: "class Missing {}",
      [`${root}/${second}`]: "class Missing {}",
    });
    const options = { ...at(3, "OrderService"), source: source.replace(/OrderService/g, "Missing") };
    options.source = options.source.replace("import com.acme.service.Missing;\n", "");
    options.line = 2;
    expect(await resolveJavaSyntaxDefinitions(options, deps)).toHaveLength(2);
  });

  test("resolves a type declared in the same file without listing the workspace", async () => {
    const deps = dependencies([]);
    const locations = await resolveJavaSyntaxDefinitions(at(4, "Helper"), deps);
    expect(locations.map((value) => value.range.start.line)).toEqual([8]);
    expect(deps.listWorkspaceFiles).not.toHaveBeenCalled();
  });

  test("resolves unqualified and this-qualified members of the file", async () => {
    const deps = dependencies([]);
    for (const occurrence of [0, 1]) {
      const locations = await resolveJavaSyntaxDefinitions(at(5, "audit", occurrence), deps);
      expect(locations.map((value) => value.range.start.line)).toEqual([6]);
    }
  });

  test("asks Core to resolve a member from where the name starts", async () => {
    const deps = dependencies([]);
    await resolveJavaSyntaxDefinitions(at(5, "save"), deps);
    expect(deps.findMemberDefinition).toHaveBeenCalledTimes(1);
    expect(deps.findMemberDefinition.mock.calls[0]).toEqual([
      source,
      "OrderController",
      "save",
      { line: 5, utf16Column: source.split("\n")[5].indexOf("save") },
    ]);
  });

  test("a name on its own declaration goes nowhere", async () => {
    expect(await resolveJavaSyntaxDefinitions(at(6, "audit"), dependencies([]))).toEqual([]);
    expect(await resolveJavaSyntaxDefinitions(at(2, "OrderController"), dependencies([]))).toEqual([]);
  });

  test("ignores files outside the workspace and positions without an identifier", async () => {
    const deps = dependencies([]);
    expect(await resolveJavaSyntaxDefinitions({ ...at(3, "service"), sourceFilePath: "D:/other/A.java" }, deps)).toEqual([]);
    expect(await resolveJavaSyntaxDefinitions({ ...at(3, "service"), line: 99 }, deps)).toEqual([]);
  });
});
