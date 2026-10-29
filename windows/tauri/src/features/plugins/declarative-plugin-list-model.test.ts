import { expect, test } from "bun:test";
import type { DeclarativePluginSummary } from "./declarative-plugin-launch";
import { EMPTY_PLUGIN_LIST_FILTERS, groupPluginList, pluginListIdentity } from "./declarative-plugin-list-model";

function plugin(pluginId: string, overrides: Partial<DeclarativePluginSummary> = {}): DeclarativePluginSummary {
  return {
    pluginId, displayName: pluginId, version: "1.0.0", apiVersion: 1,
    source: "installed", enabled: true, status: "accepted", languages: [],
    declaredSettings: [], declaresTests: false, primaryLanguageId: null, rejection: null,
    ...overrides,
  };
}

const language = { id: "demo", displayName: "Demo", fileExtensions: [".demo"], fileNames: [] };

test("quarantine takes precedence over enabled and grouping is deterministic without changing the snapshot", () => {
  const plugins = [
    plugin("io.example.z", { displayName: "Zebra" }),
    plugin("io.example.q", { status: "rejected", enabled: true }),
    plugin("io.example.a", { displayName: "Alpha" }),
    plugin("io.example.d", { enabled: false }),
  ];
  const before = JSON.stringify(plugins);
  const groups = groupPluginList(plugins, EMPTY_PLUGIN_LIST_FILTERS);
  expect(groups.map((group) => group.state)).toEqual(["enabled", "disabled", "quarantined"]);
  expect(groups[0]!.plugins.map((item) => item.displayName)).toEqual(["Alpha", "Zebra"]);
  expect(JSON.stringify(plugins)).toBe(before);
});

test("language, status and package location filters intersect only summary fields", () => {
  const wanted = plugin("io.example.language", { enabled: false, languages: [language] });
  const plugins = [wanted,
    plugin("io.example.bundled", { source: "bundled", enabled: false, languages: [language] }),
    plugin("io.example.enabled", { languages: [language] }),
    plugin("io.example.nonlanguage", { enabled: false, declaresTests: true }),
    plugin("io.example.quarantine", { status: "rejected", enabled: false }),
  ];
  const groups = groupPluginList(plugins, {
    query: "", capability: "language", state: "disabled", source: "installed",
  });
  expect(groups).toEqual([{ state: "disabled", plugins: [wanted] }]);
});

test("search is trimmed, case insensitive and matches every term in name or ID", () => {
  const wanted = plugin("io.example.language", { displayName: "Demo Support", languages: [language] });
  expect(groupPluginList([wanted], { ...EMPTY_PLUGIN_LIST_FILTERS, query: "  DEMO  example.language " })[0]!.plugins).toEqual([wanted]);
  expect(groupPluginList([wanted], { ...EMPTY_PLUGIN_LIST_FILTERS, query: "not-present" })).toEqual([]);
  // Declaring a language or tests is not evidence of publisher, build, or update state.
  expect(groupPluginList([wanted], { ...EMPTY_PLUGIN_LIST_FILTERS, query: "official" })).toEqual([]);
});

test("bundled and installed copies of one ID retain distinct selection identities", () => {
  const installed = plugin("io.example.same");
  const bundled = plugin("io.example.same", { source: "bundled" });
  const groups = groupPluginList([installed, bundled], EMPTY_PLUGIN_LIST_FILTERS);
  expect(groups[0]!.plugins.map(pluginListIdentity)).toEqual(["bundled:io.example.same", "installed:io.example.same"]);
  expect(groupPluginList([installed, bundled], { ...EMPTY_PLUGIN_LIST_FILTERS, source: "installed" })[0]!.plugins).toEqual([installed]);
});
