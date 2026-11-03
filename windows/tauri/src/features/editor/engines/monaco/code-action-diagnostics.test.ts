import { expect, test } from "bun:test";
import { diagnosticsForCodeActionMarker } from "./code-action-diagnostics";
import type { Diagnostic } from "@/features/diagnostics/types/diagnostics.types";
const error: Diagnostic = { severity: "error", filePath: "C:/work/a.ts", line: 0, column: 1, endLine: 0, endColumn: 1, message: "same", source: "lsp", code: "123", owner: "one" };
const marker = { severity: 4, startLineNumber: 1, startColumn: 2, endLineNumber: 1, endColumn: 3, message: "same", source: "lsp", code: { value: "123", target: {} as never } };
test("matches the projected severity and retains the original diagnostic identity", () => {
 const warning: Diagnostic = { ...error, severity: "warning" };
 const matches = diagnosticsForCodeActionMarker([error, warning], marker);
 expect(matches).toEqual([warning]); expect(matches[0]).toBe(warning);
});
test("preserves ambiguous originals instead of choosing the first owner", () => {
 const first: Diagnostic = { ...error, severity: "warning" };
 const second = { ...first, owner: "two" };
 expect(diagnosticsForCodeActionMarker([first, second], marker)).toEqual([first, second]);
});
