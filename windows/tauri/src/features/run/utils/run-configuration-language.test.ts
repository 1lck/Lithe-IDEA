import { expect, test } from "bun:test";
import { mapCoreConfiguration } from "./run-configuration";
import {
  runConfigurationLanguageGroups,
  runConfigurationLanguageKey,
} from "./run-configuration-language";

test("providers identify ecosystems without guessing a language from names or paths", () => {
  for (const [provider, language] of [
    ["java.main", "java"],
    ["maven.module", "java"],
    ["gradle.service", "java"],
    ["spring-boot.maven", "java"],
    ["quarkus.maven", "java"],
    ["micronaut.maven", "java"],
    ["npm.script", "nodejs"],
    ["pnpm.script", "nodejs"],
    ["bun.script", "nodejs"],
    ["typescript.command", "nodejs"],
    ["python.uvicorn", "python"],
    ["cargo.binary", "rust"],
    ["go.main", "go"],
    ["swift.command", "swift"],
    ["php.script", "php"],
    ["ruby.command", "ruby"],
    ["dotnet.run", "dotnet"],
    ["compose.service", "infrastructure"],
    ["make.target", "tools"],
    ["just.recipe", "tools"],
    ["procfile.process", "tools"],
    ["custom.command", "other"],
    ["constructor.command", "other"],
  ] as const) {
    expect(runConfigurationLanguageKey({ provider, category: "project" })).toBe(language);
  }
  expect(
    runConfigurationLanguageKey({ provider: "spring-boot.maven", category: "infrastructure" }),
  ).toBe("infrastructure");
  const unknown = mapCoreConfiguration({
    id: "custom",
    name: "Java server",
    provider: "custom.command",
    cwd: "src/java",
  });
  expect(runConfigurationLanguageKey(unknown)).toBe("other");
});

test("language groups contain only present runnable configurations in stable ecosystem order", () => {
  const entries = [
    { id: "rust", provider: "cargo.binary", execution: "application" },
    { id: "node", provider: "npm.script", execution: "service" },
    { id: "java", provider: "java.main", execution: "application" },
    { id: "maven", provider: "maven.module", execution: "task" },
    { id: "current-file", provider: "java.current-file", execution: "application" },
    { id: "compound", provider: "java.group", execution: "group" },
  ].map((entry) => mapCoreConfiguration({ ...entry, name: entry.id }));
  expect(
    runConfigurationLanguageGroups(entries).map(({ id, configurations }) => [
      id,
      configurations.map((entry) => entry.id),
    ]),
  ).toEqual([
    ["java", ["java", "maven"]],
    ["nodejs", ["node"]],
    ["rust", ["rust"]],
  ]);
  expect(runConfigurationLanguageGroups([])).toEqual([]);
});
