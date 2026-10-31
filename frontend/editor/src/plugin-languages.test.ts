import { beforeEach, expect, test } from "bun:test";
import { hasPluginGrammar, setPluginLanguages as replace, toLanguageConfiguration,
  type MonacoLanguages, type PluginLanguage } from "./plugin-languages";

// A Monaco languages double that records registrations and provider lifetimes.
const registered: { id: string; extensions: string[]; filenames: string[] }[] = [];
const live = new Map<string, number>();
let failCompile = new Set<string>();
const provider = (id: string) => {
  live.set(id, (live.get(id) ?? 0) + 1);
  return { dispose: () => live.set(id, (live.get(id) ?? 0) - 1) };
};
const monaco = {
  getLanguages: () => registered,
  register: (language: { id: string; extensions: string[]; filenames: string[] }) => registered.push(language),
  setMonarchTokensProvider: (id: string) => {
    if (failCompile.has(id)) throw new Error(`cannot compile ${id}`);
    return provider(id);
  },
  setLanguageConfiguration: (id: string) => provider(id),
} as unknown as MonacoLanguages;

const setPluginLanguages = (list: PluginLanguage[]) => replace(monaco, list);

const http = {
  id: "http", fileExtensions: ["http", ".rest"],
  grammar: { kind: "monarch" as const, monarch: { tokenizer: { root: [] } } },
  configuration: { lineComment: "#", brackets: [["{", "}"]] as [string, string][], autoClosingPairs: [["\"", "\""]] as [string, string][] },
};

beforeEach(() => {
  setPluginLanguages([]);
  failCompile = new Set();
});

test("registers a plugin language once and owns its tokenizer", () => {
  expect(setPluginLanguages([http])).toEqual({ failed: [] });
  expect(hasPluginGrammar("http")).toBe(true);
  expect(registered.filter(language => language.id === "http")).toEqual([
    { id: "http", extensions: [".http", ".rest"], filenames: [] },
  ]);
  expect(live.get("http")).toBe(2);

  // The same list keeps the providers; an empty list disposes them.
  setPluginLanguages([http]);
  expect(live.get("http")).toBe(2);
  setPluginLanguages([]);
  expect(hasPluginGrammar("http")).toBe(false);
  expect(live.get("http")).toBe(0);
  expect(registered.filter(language => language.id === "http")).toHaveLength(1);
});

test("a changed grammar replaces its providers", () => {
  setPluginLanguages([http]);
  setPluginLanguages([{ ...http, configuration: null }]);
  expect(live.get("http")).toBe(2);
  expect(hasPluginGrammar("http")).toBe(true);
});

test("a grammar Monaco rejects is reported and the others still apply", () => {
  failCompile = new Set(["broken"]);
  const broken = { ...http, id: "broken", fileExtensions: ["broken"] };
  expect(setPluginLanguages([broken, http])).toEqual({ failed: [{ id: "broken", message: "cannot compile broken" }] });
  expect(hasPluginGrammar("broken")).toBe(false);
  expect(hasPluginGrammar("http")).toBe(true);
});

test("maps contract configuration to Monaco configuration", () => {
  expect(toLanguageConfiguration(http.configuration)).toEqual({
    comments: { lineComment: "#", blockComment: undefined },
    brackets: [["{", "}"]],
    autoClosingPairs: [{ open: "\"", close: "\"" }],
    surroundingPairs: [{ open: "\"", close: "\"" }],
  });
  expect(toLanguageConfiguration(null)).toEqual({
    comments: undefined, brackets: undefined, autoClosingPairs: [], surroundingPairs: [],
  });
});
