package syntax

import (
	"fmt"
	"io/fs"
	"maps"
	"slices"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/rope"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/textmate"
)

func TestForPath(t *testing.T) {
	r := NewRegistry()
	for path, want := range map[string]string{
		"src/Main.java":            "java",
		"X.JAVA":                   "java",
		"build.gradle":             "groovy",
		"build.gradle.kts":         "kotlin",
		"Jenkinsfile":              "groovy",
		"Makefile":                 "makefile",
		"makefile.inc":             "makefile",
		"rules.mk":                 "makefile",
		`C:\x\CMakeLists.txt`:      "cmake",
		"notes.txt":                "plaintext",
		"toolchain.cmake":          "cmake",
		".env":                     "dotenv",
		".env.local":               "dotenv",
		"Dockerfile":               "dockerfile",
		"Dockerfile.dev":           "dockerfile",
		"/home/me/.zshrc":          "shell",
		"script.PS1":               "powershell",
		"lib/a.d/index.tsx":        "typescriptreact",
		"index.d.ts":               "typescript",
		"App.jsx":                  "javascriptreact",
		"vite.config.mjs":          "javascript",
		"package.json":             "json",
		"tsconfig.json":            "jsonc",
		"tsconfig.base.json":       "jsonc",
		".eslintrc":                "jsonc",
		"main.go":                  "go",
		"lib.rs":                   "rust",
		"a.h":                      "c",
		"a.hpp":                    "cpp",
		"index.html":               "html",
		"site.css":                 "css",
		"README.md":                "markdown",
		"app.properties":           "ini",
		"Cargo.toml":               "toml",
		"pom.xml":                  "xml",
		"settings/application.yml": "yaml",
	} {
		language, ok := r.ForPath(path)
		if !ok || language.ID != want {
			id := "none"
			if ok {
				id = language.ID
			}
			t.Errorf("ForPath(%q) = %s, want %s", path, id, want)
		}
	}
	for _, path := range []string{"", "dir/", "unknown.zzz", "README"} {
		if language, ok := r.ForPath(path); ok {
			t.Errorf("ForPath(%q) = %s, want none", path, language.ID)
		}
	}
}

func TestBundledLanguages(t *testing.T) {
	ids := map[string]bool{}
	for _, language := range bundledLanguages {
		if ids[language.ID] {
			t.Errorf("language %s listed twice", language.ID)
		}
		ids[language.ID] = true
		for _, list := range [][]string{language.Extensions, language.FileNames, language.FilePrefixes} {
			for _, s := range list {
				if s != strings.ToLower(s) || s == "" {
					t.Errorf("%s: association %q is not lower case", language.ID, s)
				}
			}
		}
		for _, extension := range language.Extensions {
			if extension[0] != '.' {
				t.Errorf("%s: extension %q has no dot", language.ID, extension)
			}
		}
		if language.Scope != "" {
			if _, ok := bundledGrammars[language.Scope]; !ok {
				t.Errorf("%s: no bundled grammar for scope %s", language.ID, language.Scope)
			}
		}
	}
	for alias, id := range languageAliases {
		if !ids[id] {
			t.Errorf("alias %s maps to unknown language %s", alias, id)
		}
		if ids[alias] {
			t.Errorf("alias %s is also a bundled language", alias)
		}
	}
}

func TestBundledGrammars(t *testing.T) {
	r := NewRegistry()
	files, err := fs.Glob(grammarFiles, "grammars/*.tmLanguage.json")
	if err != nil {
		t.Fatal(err)
	}
	for _, file := range files {
		if !slices.Contains(slices.Collect(maps.Values(bundledGrammars)), file) {
			t.Errorf("%s is embedded but has no scope in bundledGrammars", file)
		}
	}
	for scope := range bundledGrammars {
		raw := loadBundledGrammar(scope)
		if raw == nil || raw.ScopeName != scope {
			t.Fatalf("grammar for %s has scope %v", scope, raw)
		}
	}
	for _, language := range bundledLanguages {
		if language.Scope == "" {
			if r.Syntax(language.ID) != nil {
				t.Errorf("%s has no grammar but a Syntax", language.ID)
			}
			continue
		}
		s := r.Syntax(language.ID)
		if s == nil {
			t.Fatalf("no Syntax for %s", language.ID)
		}
		if r.Syntax(language.ID) != s {
			t.Errorf("Syntax for %s compiled twice", language.ID)
		}
		h := testHighlighter(s, rope.FromString("# x\n"), 0, nil)
		if len(h.Line(nil, 0)) == 0 {
			t.Errorf("%s: no tokens", language.ID)
		}
	}
}

func TestCanonicalID(t *testing.T) {
	for id, want := range map[string]string{
		"java": "java", "typescriptreact": "typescriptreact", "jsonc": "jsonc", "vue": "html", "bash": "shell",
		"make": "makefile", "text": "plaintext", "terraform": "hcl", "unknown": "unknown",
	} {
		if got := CanonicalID(id); got != want {
			t.Errorf("CanonicalID(%q) = %q, want %q", id, got, want)
		}
	}
	r := NewRegistry()
	if language, ok := r.Language("make"); !ok || language.ID != "makefile" {
		t.Fatalf("Language(make) = %v, %v", language, ok)
	}
}

const demoGrammar = `{
	"scopeName": "source.demo",
	"patterns": [
		{"match": "\\bfoo\\b", "name": "keyword.control.demo"},
		{"match": "#.*$", "name": "comment.line.number-sign.demo"}
	]
}`

func TestPluginLanguages(t *testing.T) {
	r := NewRegistry()
	version := r.Version()
	demo := PluginLanguage{ID: "demo", Extensions: []string{"DEMO", ".dm"}, FileNames: []string{"Demofile"},
		Grammar: []byte(demoGrammar), Comments: Comments{Line: "#"}}
	failed, removed := r.SetPluginLanguages([]PluginLanguage{demo})
	if len(failed) != 0 || len(removed) != 0 || r.Version() == version {
		t.Fatalf("add: failed %v, removed %v, version %d after %d", failed, removed, r.Version(), version)
	}
	for _, path := range []string{"a.demo", "b.DM", "x/demofile"} {
		if language, ok := r.ForPath(path); !ok || language.ID != "demo" {
			t.Fatalf("ForPath(%q) = %v, %v", path, language, ok)
		}
	}
	s := r.Syntax("demo")
	if s == nil {
		t.Fatal("no Syntax for the plugin language")
	}
	h := testHighlighter(s, rope.FromString("foo bar # c"), 0, nil)
	want := []Token{{0, Intern("keyword")}, {3, 0}, {8, Intern("comment.line")}}
	if got := h.Line(nil, 0); !slices.Equal(got, want) {
		t.Fatalf("plugin grammar tokens %v, want %v", got, want)
	}

	// The same list changes nothing and keeps the compiled syntax.
	version = r.Version()
	r.SetPluginLanguages([]PluginLanguage{demo})
	if r.Version() != version || r.Syntax("demo") != s {
		t.Fatal("setting the same languages again changed the registry")
	}

	// A plugin language for a bundled one inherits what it does not set.
	java := PluginLanguage{ID: "java", Extensions: []string{"jsh"}}
	broken := PluginLanguage{ID: "broken", Grammar: []byte("{")}
	clash := PluginLanguage{ID: "clash", Grammar: []byte(demoGrammar)}
	failed, _ = r.SetPluginLanguages([]PluginLanguage{demo, java, broken, clash})
	if len(failed) != 2 || failed[0].ID != "broken" || failed[1].ID != "clash" {
		t.Fatalf("failed %v, want broken and clash", failed)
	}
	language, ok := r.ForPath("Script.jsh")
	if !ok || language.ID != "java" || language.Scope != "source.java" || language.Comments.Line != "//" {
		t.Fatalf("ForPath(Script.jsh) = %+v, %v", language, ok)
	}
	if language, ok := r.ForPath("Main.java"); !ok || language.ID != "java" || slices.Contains(language.Extensions, ".java") {
		t.Fatalf("ForPath(Main.java) = %+v, %v, want the plugin's java", language, ok)
	}

	// A plugin grammar of a bundled scope replaces it until the plugin goes.
	override := PluginLanguage{ID: "java", Grammar: []byte(strings.Replace(demoGrammar, "source.demo", "source.java", 1))}
	r.SetPluginLanguages([]PluginLanguage{override})
	h = testHighlighter(r.Syntax("java"), rope.FromString("foo"), 0, nil)
	if got := h.Line(nil, 0); !slices.Equal(got, []Token{{0, Intern("keyword")}}) {
		t.Fatalf("plugin Java grammar tokens %v", got)
	}
	_, removed = r.SetPluginLanguages(nil)
	if !slices.Equal(removed, []string{"java"}) {
		t.Fatalf("removed %v, want java", removed)
	}
	h = testHighlighter(r.Syntax("java"), rope.FromString("class A {}"), 0, nil)
	if got := h.Line(nil, 0); len(got) == 0 || got[0].Name != Intern("keyword.java") {
		t.Fatalf("bundled Java grammar not restored: tokens %v", got)
	}
	if _, ok := r.ForPath("a.demo"); ok {
		t.Fatal("a removed plugin language still matches files")
	}
}

// tokenNames returns, for each text in want, the name of the token text starts in, at its first
// occurrence in source.
func tokenNames(t *testing.T, s *Syntax, source string, want map[string]string) map[string]string {
	t.Helper()
	lines := reference(s, rope.FromString(source))
	got := map[string]string{}
	for text := range want {
		at := strings.Index(source, text)
		if at < 0 {
			t.Fatalf("%q is not in the source", text)
		}
		line := strings.Count(source[:at], "\n")
		column := at - (strings.LastIndex(source[:at], "\n") + 1)
		name := Name(0)
		for i := 0; i+1 < len(lines[line]); i += 2 {
			if int(lines[line][i]) <= column {
				name = Name(lines[line][i+1])
			}
		}
		got[text] = name.String()
	}
	return got
}

// TestLanguageTokenNames checks that the bundled languages name their tokens as the previous
// editor did, the names color schemes style, and that embedded languages are named by their
// own rules.
func TestLanguageTokenNames(t *testing.T) {
	for _, c := range []struct {
		language, source string
		want             map[string]string
	}{
		{"html", "<!DOCTYPE html>\n<div class=\"a\">&amp; <!-- c --></div>\n" +
			"<style>\np { color: #fff; }\n</style>\n<script>let x = /a+/;</script>\n", map[string]string{
			"<!DOCTYPE": "metatag.html", "<div": "delimiter.html", "div": "tag.html", "class": "attribute.name.html",
			"=": "delimiter.html", `"a"`: "attribute.value.html", "&amp;": "string.escape.html", "<!--": "comment.html",
			"p {": "tag.css", "</style": "delimiter.html", "color": "attribute.name.css", "#fff": "attribute.value.hex.css",
			"let": "keyword", "/a+/": "regexp",
		}},
		{"xml", "<?xml version=\"1.0\"?>\n<a:b x=\"1\">&lt;<!-- c --></a:b>\n", map[string]string{
			"version": "attribute.name.xml", `"1.0"`: "attribute.value.xml", "<a:b": "delimiter.xml", "a:b": "tag.xml",
			"x=": "attribute.name.xml", "&lt;": "string.escape.xml", "<!--": "comment.xml",
		}},
		{"css", "@media screen {\n  .a > p { margin: 10px auto; color: red; }\n}\n/* c */\n", map[string]string{
			"@media": "keyword.css", ".a": "tag.css", "p {": "tag.css", "margin": "attribute.name.css",
			"10": "attribute.value.number.css", "px": "attribute.value.unit.css", "auto": "attribute.value.css",
			"/* c": "comment.css", "{\n": "delimiter.bracket.css",
		}},
		{"json", "{\"a\": [1, true, \"s\"]}\n", map[string]string{
			`"a"`: "string.key.json", "1,": "number.json", "true": "keyword.json", `"s"`: "string.value.json",
			"{": "delimiter.bracket.json", "[": "delimiter.array.json", ":": "delimiter.colon.json", ",": "delimiter.comma.json",
		}},
		{"jsonc", "// c\n{\"a\": 1}\n", map[string]string{"// c": "comment.line.json", `"a"`: "string.key.json"}},
		{"yaml", "%YAML 1.2\n---\nkey: value\nq: \"s\"\nn: 1\nb: true\na: &x 1\nr: *x\nt: !!str v\n# c\nl:\n  - i\n", map[string]string{
			"%YAML": "meta.directive.yaml", "---": "operators.directivesEnd.yaml", "key": "type.yaml", ": value": "operators.yaml",
			"value": "string.yaml.plain", `"s"`: "string.yaml", "1\n": "number.yaml", "true": "keyword.yaml",
			"&x": "namespace.yaml", "*x": "namespace.yaml", "!!str": "tag.yaml", "# c": "comment.yaml", "- i": "operators.yaml",
		}},
		{"markdown", "---\ntitle: x\n---\n# Head\n> quote\n- item `code` **b** *i* [text](http://x)\n```go\nfunc main() {}\n```\n", map[string]string{
			"title": "type.yaml", "# ": "keyword.md", "Head": "keyword.md.heading", "> ": "comment.md", "- ": "keyword.md",
			"`code`": "variable.md", "**b**": "strong", "*i*": "emphasis", "text": "md.link", "http": "string.link.md",
			"```go": "string.md", "func": "keyword",
		}},
		{"ini", "; c\n[section]\nkey = \"v\"\n", map[string]string{
			"; c": "comment.ini", "[": "metatag.ini", "section": "metatag.ini", "key": "key.ini", "=": "delimiter.ini", `"v"`: "string.ini",
		}},
		{"toml", "# c\n[server.http]\nport = 80\nname = \"x\"\non = true\n[[items]]\n", map[string]string{
			"# c": "comment.toml", "[server": "type.toml", "server": "type.toml", "port": "key.toml", "80": "number.toml",
			`"x"`: "string.toml", "true": "keyword.toml", "[[": "type.toml", "items": "type.toml",
		}},
		{"dotenv", "# c\nexport KEY=\"v $X\"\nB=plain\n", map[string]string{
			"# c": "comment.dotenv", "export": "keyword.dotenv", "KEY": "key.dotenv", "=\"": "delimiter.dotenv",
			`"v`: "string.dotenv", "plain": "string.dotenv",
		}},
		{"typescript", "const r = /x\\d+/g; // c\nlet s = `a${b(1)}`;\nif (typeof s === \"x\") {}\nconst f = () => 1;\n", map[string]string{
			"const": "keyword", "/x": "regexp", "+/g": "regexp", "// c": "comment.line", "= /": "delimiter",
			"`a": "string", "b(": "function", "(1)": "delimiter.parenthesis", "typeof": "keyword", "===": "delimiter", "=>": "delimiter",
		}},
		{"go", "package main\n\nfunc main() { _ = \"s\"; x := 0x1F + 1e-5 }\n", map[string]string{
			"package": "keyword", "func": "keyword", `"s"`: "string", ":=": "delimiter", "0x1F": "number", "-5": "number", "+ 1": "delimiter",
		}},
		{"rust", "fn main() { let x = 1; std::mem::drop(x); }\n", map[string]string{
			"fn": "keyword", "let": "keyword", "1;": "number", "= 1": "delimiter", "::": "delimiter",
		}},
		{"cpp", "#include <x>\nint main() { return not 0 && sizeof(int); }\n", map[string]string{
			"int": "keyword", "return": "keyword", "0 ": "number", "not": "keyword", "&&": "delimiter", "sizeof": "keyword",
		}},
	} {
		t.Run(c.language, func(t *testing.T) {
			got := tokenNames(t, testSyntax(t, c.language), c.source, c.want)
			for text, want := range c.want {
				if got[text] != want {
					t.Errorf("%q is %q, want %q", text, got[text], want)
				}
			}
		})
	}
}

func TestIncludedGrammarsLoadWhenReached(t *testing.T) {
	r := NewRegistry()
	var loaded []string
	r.grammars = textmate.NewLazyRegistry(hasBundledGrammar, func(scope string) *textmate.RawGrammar {
		loaded = append(loaded, scope)
		return loadBundledGrammar(scope)
	})
	syntax := r.Syntax("markdown")
	if syntax == nil {
		t.Fatal("no markdown syntax")
	}
	if fmt.Sprint(loaded) != "[text.html.markdown]" {
		t.Fatalf("opening markdown loaded %v", loaded)
	}
	tokenizer := syntax.grammar.NewTokenizer()
	var state *textmate.StateStack
	for _, line := range []string{"# Title", "", "```go", "package main", "```"} {
		_, state, _ = tokenizer.TokenizeLine(nil, []byte(line+"\n"), state, 0)
	}
	if !slices.Contains(loaded, "source.go") || slices.Contains(loaded, "source.rust") {
		t.Fatalf("a go fence loaded %v", loaded)
	}
}
