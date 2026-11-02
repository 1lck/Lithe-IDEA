import type { languages } from "monaco-editor";
import { deepClone } from "monaco-editor/esm/vs/base/common/objects.js";

/** Preserve upstream parsing while exposing language-specific roles without changing other themes. */
export function refineLanguageTokenRoles(source: languages.IMonarchLanguage, languageID: string): languages.IMonarchLanguage {
  if (!["yaml", "sql", "markdown", "python"].includes(languageID)) return source;
  const language = deepClone(source);
  // Put the language before the new subtype, so non-IDEA themes still inherit
  // their exact string.yaml rule (including Monaco's built-in light override).
  const suffix = language.tokenPostfix ?? `.${languageID}`;
  language.tokenPostfix = "";
  language.brackets = language.brackets?.map(bracket => ({ ...bracket, token: bracket.token + suffix }));
  const actionWithRole = (action: languages.IMonarchLanguageAction, state: string, branch = ""): languages.IMonarchLanguageAction => {
    if (typeof action === "string") {
      if (!action || action.startsWith("@")) return action;
      const plain = languageID === "yaml" && action === "string"
        && ["root", "object", "array", "multiString", "multiStringContinued"].includes(state);
      const word = languageID === "sql" && branch === "@operators";
      return action + suffix + (plain ? ".plain" : word ? ".word" : "");
    }
    if (Array.isArray(action)) return action.map(value => actionWithRole(value, state, branch)) as languages.IMonarchLanguageAction;
    return { ...action,
      ...(typeof action.token === "string" ? { token: actionWithRole(action.token, state, branch) as string } : {}),
      ...(action.cases ? { cases: Object.fromEntries(Object.entries(action.cases)
        .map(([key, value]) => [key, actionWithRole(value, state, key)])) } : {}),
    };
  };
  for (const [state, rules] of Object.entries(language.tokenizer)) {
    language.tokenizer[state] = rules.map(rule => {
      if (!Array.isArray(rule)) return rule;
      return [rule[0], actionWithRole(rule[1], state), ...rule.slice(2)] as languages.IMonarchLanguageRule;
    });
  }
  if (languageID === "python") {
    // Monaco marks quote delimiters as escapes, but actual backslash escapes as
    // strings. Give the latter a subtype without changing other palettes.
    for (const rules of Object.values(language.tokenizer)) for (const rule of rules) {
      if (Array.isArray(rule) && rule[0] instanceof RegExp && rule[0].source === "\\\\."
        && rule[1] === "string.python") rule[1] = "string.python.escape";
    }
  }
  if (languageID === "markdown") {
    // Preserve Monarch's parser and the original parent tokens in other schemes.
    for (const rule of language.tokenizer.root) {
      if (Array.isArray(rule) && Array.isArray(rule[1]) && rule[1].length === 4
        && rule[1][1] === "keyword.md") rule[1][2] = "keyword.md.heading";
    }
    for (const rule of language.tokenizer.linecontent) {
      if (Array.isArray(rule) && Array.isArray(rule[1]) && rule[1][0] === "string.link.md")
        rule[1][1] = "md.link";
    }
  }
  if (languageID === "sql") {
    // This keyword is also listed as a builtin function by Monaco 0.55.1.
    // Append a subtype to retain predefined.sql in every other theme.
    const wordRule = language.tokenizer.root.find(rule => Array.isArray(rule)
      && typeof rule[1] === "object" && !Array.isArray(rule[1]) && rule[1].cases?.["@builtinFunctions"]);
    if (Array.isArray(wordRule)) {
      const action = wordRule[1] as languages.IExpandedMonarchLanguageAction;
      action.cases = { "~COLLATE": "predefined.sql.keyword", ...action.cases };
    }
  }
  return language;
}
