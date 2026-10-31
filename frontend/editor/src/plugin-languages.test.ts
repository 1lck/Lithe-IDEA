import { beforeEach, expect, test } from "bun:test";
import { hasPluginGrammar, pluginLanguageForFilename, setPluginLanguages as replace, toLanguageConfiguration,
  type MonacoLanguages, type PluginLanguage } from "./plugin-languages";

const registered: { id: string }[] = [];
const live = new Map<string, number>();
let failCompile = new Set<string>();
const inherited: [string, string][] = [];
const provider = (id: string) => {
  live.set(id, (live.get(id) ?? 0) + 1);
  return { dispose: () => live.set(id, (live.get(id) ?? 0) - 1) };
};
const monaco = {
  getLanguages: () => registered,
  register: (language: { id: string }) => registered.push(language),
  setLanguageConfiguration: (id: string) => provider(id),
} as unknown as MonacoLanguages;
const install = (id: string) => {
  if (failCompile.has(id)) throw new Error(`cannot compile ${id}`);
  return provider(id);
};
const setPluginLanguages = (list: PluginLanguage[]) => replace(monaco, list, install, (id, alias) => {
  inherited.push([id, alias]);
  return provider(id);
});
const http: PluginLanguage = {
  id: "http", fileExtensions: ["http", ".rest"],
  grammar: { kind: "monarch", source: '{"tokenizer":{"root":[]}}' },
  configuration: { lineComment: "#", brackets: [["{", "}"]], autoClosingPairs: [["\"", "\""]] },
};
beforeEach(() => { setPluginLanguages([]); failCompile = new Set(); inherited.length = 0; });

test("owns providers, matches only active file types and disposes on withdrawal", () => {
  try {
    expect(setPluginLanguages([http])).toEqual({ failed: [], removed: [] });
    expect(hasPluginGrammar("http")).toBe(true);
    expect(live.get("http")).toBe(2);
    expect(pluginLanguageForFilename("users.REST")).toBe("http");
    setPluginLanguages([http]);
    expect(live.get("http")).toBe(2);
    setPluginLanguages([]);
    expect(hasPluginGrammar("http")).toBe(false);
    expect(pluginLanguageForFilename("users.http")).toBeUndefined();
    expect(live.get("http")).toBe(0);
    expect(registered.filter(value => value.id === "http")).toHaveLength(1);
  } finally { setPluginLanguages([]); }
});

test("updates file matching and keeps plugin IDs distinct from tokenizer aliases", () => {
  try {
    setPluginLanguages([{ ...http, id: "properties", fileExtensions: ["properties"] }]);
    expect(pluginLanguageForFilename("a.properties")).toBe("properties");
    setPluginLanguages([{ ...http, id: "properties", fileExtensions: ["newproperties"] }]);
    expect(pluginLanguageForFilename("a.properties")).toBeUndefined();
    expect(pluginLanguageForFilename("a.newproperties")).toBe("properties");
    expect(hasPluginGrammar("ini")).toBe(false);
  } finally { setPluginLanguages([]); }
});

test("configuration does not require a grammar or backend", () => {
  try {
    setPluginLanguages([{ ...http, grammar: null }]);
    expect(live.get("http")).toBe(1);
    expect(hasPluginGrammar("http")).toBe(false);
    expect(pluginLanguageForFilename("a.http")).toBe("http");
  } finally { setPluginLanguages([]); }
});

test("a refused grammar does not prevent another file type from applying", () => {
  try {
    failCompile.add("broken");
    expect(setPluginLanguages([{ ...http, id: "broken" }, http]).failed)
      .toEqual([{ id: "broken", message: "cannot compile broken" }]);
    expect(hasPluginGrammar("broken")).toBe(false);
    expect(hasPluginGrammar("http")).toBe(true);
  } finally { setPluginLanguages([]); }
});

test("configuration-only aliases borrow and withdraw their existing tokenizer", () => {
  try {
    setPluginLanguages([{ ...http, id: "properties", fileExtensions: ["properties"], grammar: null },
      { ...http, id: "bash", fileExtensions: ["sh"], grammar: null },
      { ...http, id: "systemrdl", fileExtensions: ["rdl"], grammar: null }]);
    expect(inherited).toEqual([["properties", "ini"], ["bash", "shell"]]);
    expect(pluginLanguageForFilename("a.properties")).toBe("properties");
    expect(hasPluginGrammar("properties")).toBe(false);
    expect(live.get("properties")).toBe(2);
    expect(live.get("systemrdl")).toBe(1);
    setPluginLanguages([]);
    expect(live.get("properties")).toBe(0);
    expect(live.get("bash")).toBe(0);
  } finally { setPluginLanguages([]); }
});

test("maps bounded editing configuration", () => {
  expect(toLanguageConfiguration(http.configuration)).toEqual({
    comments: { lineComment: "#", blockComment: undefined }, brackets: [["{", "}"]],
    autoClosingPairs: [{ open: "\"", close: "\"" }], surroundingPairs: [{ open: "\"", close: "\"" }],
  });
});
