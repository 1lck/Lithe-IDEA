import { expect, test } from "bun:test";
import {
  registerPluginSettingsPages,
  type PluginSettingsContribution,
} from "./declarative-settings-pages";

test("language and build page declarations register once and retain section ownership", () => {
  const contribution: PluginSettingsContribution = {
    pluginId: "example.plugin",
    displayName: "Fixture",
    languageId: "fixture",
    actions: [
      {
        id: "action",
        title: "Action",
        function: "fixture.action",
        page: { languageID: "fixture" },
        section: "Maintenance",
      },
    ],
    settings: [
      { id: "details", title: "Details only", type: "boolean", default: false },
      {
        id: "server",
        title: "Server",
        type: "boolean",
        default: true,
        page: { languageID: "fixture" },
        section: "Server",
      },
      {
        id: "build",
        title: "Build",
        type: "text",
        default: "",
        page: { buildSystemID: "example-build" },
        section: "Tasks",
      },
    ],
  };
  const pages = registerPluginSettingsPages([contribution]);
  expect(pages.map((page) => [page.id, page.group])).toEqual([
    ["plugin-settings:build:example-build", "build"],
    ["plugin-settings:language:fixture", "languages"],
  ]);
  expect(pages[1].contributions).toHaveLength(1);
  expect(pages[1].contributions[0].settings.map((item) => [item.id, item.section])).toEqual([
    ["server", "Server"],
  ]);
  expect(pages[1].contributions[0].actions[0].section).toBe("Maintenance");
  expect(
    pages
      .flatMap((page) => page.contributions.flatMap((plugin) => plugin.settings))
      .some((item) => item.id === "details"),
  ).toBe(false);
  expect(contribution.settings).toHaveLength(3);
}, 1000);

test("multiple plugins share a page while removed plugins leave no routes", () => {
  const plugin = (pluginId: string): PluginSettingsContribution => ({
    pluginId,
    displayName: pluginId,
    languageId: "fixture",
    actions: [],
    settings: [
      {
        id: "option",
        title: "Option",
        type: "boolean",
        default: true,
        page: { languageID: "fixture" },
      },
    ],
  });
  expect(
    registerPluginSettingsPages([plugin("one"), plugin("two")])[0].contributions.map(
      (item) => item.pluginId,
    ),
  ).toEqual(["one", "two"]);
  expect(registerPluginSettingsPages([])).toEqual([]);
}, 1000);
