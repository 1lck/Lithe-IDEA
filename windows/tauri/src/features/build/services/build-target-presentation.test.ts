import { expect, test } from "bun:test";
import { buildTargetChoices } from "./build-target-presentation";
import type { BuildModel } from "./build-provider-workspace";

const instance = { pluginID: "dev.example.build", buildSystemID: "example", root: "reactor", options: {} };
const manifest = { buildSystems: [{ id: "example", run: [
  { id: "serve", name: "Serve", source: "provider", execution: "service", fromTargets: { tags: ["service"] } },
  { id: "run", name: "Run", source: "provider", fromTargets: { tags: ["application"] } },
  { id: "command", name: "Command", fromTargets: { tags: ["application"] } },
] }] };
const model: BuildModel = { projects: ["a", "b"].map(id => ({ id, name: id, path: id, properties: {} })),
  targets: ["a", "b"].flatMap(id => ["service", "application"].map(tag => ({ id: `${id}:${tag}`, projectID: id, name: "Same name",
    path: id, tags: [tag], properties: {} }))), tasks: [], contentRoots: [], optionValues: {} };

test("target choices retain exact project IDs and declared execution without inferring commands", () => {
  const choices = buildTargetChoices(manifest, instance, model, "a");
  expect(choices.map(choice => choice.reference)).toEqual([
    { pluginID: instance.pluginID, buildSystemID: "example", root: "reactor", run: "serve", projectID: "a", targetID: "a:service", execution: "service", userArguments: [] },
    { pluginID: instance.pluginID, buildSystemID: "example", root: "reactor", run: "run", projectID: "a", targetID: "a:application", execution: "application", userArguments: [] },
  ]);
  expect(buildTargetChoices(manifest, instance, model, "b").every(choice => choice.reference.projectID === "b")).toBe(true);
  choices[0]!.reference.userArguments.push("local draft");
  expect(buildTargetChoices(manifest, instance, model, "a")[0]!.reference.userArguments).toEqual([]);
});

test("workspace, missing, ambiguous or truncated project facts expose no Run selectors", () => {
  expect(buildTargetChoices(manifest, instance, model)).toEqual([]);
  expect(buildTargetChoices(manifest, instance, model, "missing")).toEqual([]);
  expect(buildTargetChoices(manifest, instance, { ...model, truncated: true }, "a")).toEqual([]);
  expect(buildTargetChoices(manifest, instance, { ...model, projects: [...model.projects, model.projects[0]!] }, "a")).toEqual([]);
});
