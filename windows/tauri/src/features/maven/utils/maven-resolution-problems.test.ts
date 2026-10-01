import { expect, test } from "bun:test";
import type { Diagnostic } from "@/features/diagnostics/types/diagnostics.types";
import {
  mavenResolutionProblems,
  mavenResolutionProblemsSignature,
} from "./maven-resolution-problems";

function diagnostic(
  filePath: string,
  severity: Diagnostic["severity"],
  message: string,
  line = 0,
): Diagnostic {
  return { severity, filePath, line, column: 4, endLine: line, endColumn: 8, message };
}

function byOwner(entries: [string, string, Diagnostic[]][]) {
  const map = new Map<string, Map<string, Diagnostic[]>>();
  for (const [filePath, owner, diagnostics] of entries) {
    const owners = map.get(filePath) ?? new Map<string, Diagnostic[]>();
    owners.set(owner, diagnostics);
    map.set(filePath, owners);
  }
  return map;
}

test("reports language-server errors on workspace pom.xml files as Maven problems", () => {
  // #970: an unresolved dependency was only visible as a pom.xml marker, so
  // the import looked successful while every third-party import stayed red.
  const rootPom = "D:/waibao/qingsheng/qingsheng-server/pom.xml";
  const modulePom = "D:\\waibao\\qingsheng\\qingsheng-server\\service\\pom.xml";
  const problems = mavenResolutionProblems(
    "D:\\waibao\\qingsheng\\qingsheng-server",
    byOwner([
      [modulePom, "lsp", [diagnostic(modulePom, "error", "Missing artifact org.example:lib:jar:1.0", 12)]],
      [
        rootPom,
        "lsp",
        [
          diagnostic(rootPom, "warning", "Project configuration is not up-to-date"),
          diagnostic(rootPom, "error", "Non-resolvable parent POM", 7),
        ],
      ],
      [rootPom.replace("pom.xml", "src/Main.java"), "lsp", [diagnostic("Main.java", "error", "x")]],
      ["D:/other/pom.xml", "lsp", [diagnostic("D:/other/pom.xml", "error", "elsewhere")]],
    ]),
  );

  expect(problems).toEqual([
    { pomPath: rootPom, modulePath: ".", line: 7, column: 4, message: "Non-resolvable parent POM" },
    {
      pomPath: modulePom,
      modulePath: "service",
      line: 12,
      column: 4,
      message: "Missing artifact org.example:lib:jar:1.0",
    },
  ]);
});

test("ignores diagnostics owned by other producers and a workspace without a root", () => {
  const pom = "C:/work/pom.xml";
  const diagnostics = byOwner([[pom, "linter", [diagnostic(pom, "error", "lint")]]]);

  expect(mavenResolutionProblems("C:/work", diagnostics)).toEqual([]);
  expect(mavenResolutionProblems(null, diagnostics)).toEqual([]);
});

test("the signature identifies a problem set independent of object identity", () => {
  const pom = "C:/work/pom.xml";
  const first = mavenResolutionProblems("C:/work", byOwner([[pom, "lsp", [diagnostic(pom, "error", "a")]]]));
  const same = mavenResolutionProblems("C:/work", byOwner([[pom, "lsp", [diagnostic(pom, "error", "a")]]]));
  const other = mavenResolutionProblems("C:/work", byOwner([[pom, "lsp", [diagnostic(pom, "error", "b")]]]));

  expect(mavenResolutionProblemsSignature(first)).toBe(mavenResolutionProblemsSignature(same));
  expect(mavenResolutionProblemsSignature(first)).not.toBe(mavenResolutionProblemsSignature(other));
  expect(mavenResolutionProblemsSignature([])).toBe("");
});
