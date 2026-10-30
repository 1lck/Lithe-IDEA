import { expect, test } from "bun:test";
import { buildTaskChoices, buildTaskRows } from "./build-task-presentation";
import type { BuildModel } from "./build-provider-workspace";

const instance = { pluginID: "dev.example.build", buildSystemID: "example", root: ".", options: {} };
const manifest = { buildSystems: [{ id: "example", tasks: [
  { id: "compile", displayName: "Compile", group: "build", source: "provider", scopes: ["workspace", "project"], category: ["Lifecycle"] },
  { id: "custom", displayName: "Custom", group: "other", source: "provider", scopes: ["project"], requiresUserArguments: true },
  { id: "template", displayName: "Template", group: "build", source: "provider", fromModel: true, category: ["Plugins"], requiresUserArguments: true },
  { id: "command", displayName: "Command", group: "build", scopes: ["workspace"] },
  { id: "server", displayName: "Server", source: "provider", scopes: ["workspace"], execution: "service" },
] }] };
const model: BuildModel = { projects: ["a", "b"].map(id => ({ id, name: id, path: id, properties: {} })),
  tasks: ["a", "b"].map(id => ({ id: `${id}:compile`, projectID: id, name: "Compile plugin", path: id, template: "template", execution: "task", properties: {} })),
  targets: [], contentRoots: [], optionValues: {} };

test("workspace and project catalogs preserve declared scope without treating templates as ordinary tasks", () => {
  expect(buildTaskChoices(manifest, instance, model).map(choice => choice.task)).toEqual(["compile"]);
  const choices = buildTaskChoices(manifest, instance, model, "a");
  expect(choices.map(choice => choice.id)).toEqual(["declared:compile", "declared:custom", "model:a:compile"]);
  expect(choices[0]).toMatchObject({ task: "compile", projectID: "a", requiresArguments: false });
  expect(choices[2]).toMatchObject({ task: "template", modelTaskID: "a:compile", projectID: "a", requiresArguments: true, category: ["Plugins"] });
  expect(buildTaskChoices(manifest, instance, model, "b")[2]?.modelTaskID).toBe("b:compile");
  expect(buildTaskChoices(manifest, instance, model, "removed")).toEqual([]);
});

test("model presentation overrides the template while categories retain catalog order", () => {
  const selected = structuredClone(model);
  selected.tasks[0] = { ...selected.tasks[0]!, displayName: "Upstream title", category: ["Upstream", "Category"], description: "Upstream help" };
  const choices = buildTaskChoices(manifest, instance, selected, "a");
  const rows = buildTaskRows(choices, group => `localized ${group}`);
  expect(rows.filter(row => "heading" in row).map(row => row.heading)).toEqual(["Lifecycle", "localized other", "Upstream / Category"]);
  expect(choices[2]).toMatchObject({ title: "Upstream title", description: "Upstream help" });
  selected.tasks[0]!.execution = "service";
  expect(buildTaskChoices(manifest, instance, selected, "a")).toHaveLength(2);
});
