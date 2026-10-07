import { expect, test } from "bun:test";
import { springPropertyCompletions } from "./spring-property-completion";
import type { SpringProperty } from "../types/spring.types";

const properties: SpringProperty[] = [
  {
    name: "server.port",
    typeName: "java.lang.Integer",
    description: "HTTP port from metadata",
    defaultValue: "8080",
  },
  { name: "spring.application.name", typeName: "java.lang.String" },
  { name: "example.custom.setting", description: "Application-provided metadata" },
];
function complete(line: string, column = line.length + 1, changes = {}) {
  return springPropertyCompletions({
    filePath: "C:/work/app/src/main/resources/application.properties",
    root: "C:/work/app",
    properties,
    line,
    column,
    lineNumber: 3,
    ...changes,
  });
}

test("completes the whole dotted key and presents dependency metadata", () => {
  const result = complete("server.");
  expect(result.suggestions).toHaveLength(1);
  expect(result.suggestions[0]).toMatchObject({
    label: "server.port",
    insertText: "server.port=",
    documentation: "HTTP port from metadata",
    detail: "java.lang.Integer = 8080",
    range: { startLineNumber: 3, endLineNumber: 3, startColumn: 1, endColumn: 8 },
  });
  expect(complete("example.").suggestions[0].label).toBe("example.custom.setting");
});

test("editing inside a key preserves an existing value and indentation", () => {
  const suggestion = complete("  server.port=9090", 10).suggestions[0];
  expect(suggestion.insertText).toBe("server.port");
  expect(suggestion.range.startColumn).toBe(3);
  expect(suggestion.range.endColumn).toBe(14);
  expect(complete("server.port 9090", 8).suggestions[0].insertText).toBe("server.port");
});

test("does not propose keys inside values, comments, or continued values", () => {
  for (const line of ["server.port=server.", "# server.", "! spring.", "server.port 80"]) {
    expect(complete(line).suggestions).toHaveLength(0);
  }
  expect(
    complete("server.", 8, { previousLine: "example.value=continued\\" }).suggestions,
  ).toHaveLength(0);
});

test("is scoped to application profile properties in the owning workspace", () => {
  expect(
    complete("spring.", 8, { filePath: "C:/work/app/application-dev.properties" }).suggestions,
  ).toHaveLength(1);
  for (const changes of [
    { root: null },
    { root: "D:/other" },
    { filePath: "C:/work/application.properties" },
    { filePath: "C:/work/app/settings.ini" },
    { filePath: "C:/work/app/application.yaml" },
  ])
    expect(complete("spring.", 8, changes).suggestions).toHaveLength(0);
});

test("bounds broad suggestions and marks the list incomplete for a narrower retry", () => {
  const many = Array.from({ length: 205 }, (_, i) => ({ name: `custom.key${i}` }));
  const result = complete("", 1, { properties: many });
  expect(result.suggestions).toHaveLength(200);
  expect(result.incomplete).toBe(true);
  expect(complete("custom.key204", 14, { properties: many }).suggestions).toHaveLength(1);
});
