package syntax

import (
	"embed"
	"encoding/json"
	"strings"
	"sync"
)

// The bundled syntax color schemes. Lithe's own palette is the default; the others replace only
// syntax colors, never the workbench's.
const (
	SchemeLithe  = "lithe"
	SchemeGitHub = "github"
	SchemeOne    = "one"
	SchemeVSCode = "vscode"
	SchemeIDEA   = "idea"
)

//go:embed schemes/*.json
var schemeFiles embed.FS

// PaletteColor is a palette role's color in light and in dark appearance, each "#RRGGBB" or
// "#RRGGBBAA".
type PaletteColor struct {
	Light string `json:"light"`
	Dark  string `json:"dark"`
}

// Palette is the base syntax colors by role: text, keyword, string, comment and the rest of
// the roles the user's syntax color settings name.
type Palette map[string]PaletteColor

// DefaultPalette returns Lithe's own palette. The caller owns the returned map.
func DefaultPalette() Palette {
	var file struct {
		Defaults Palette `json:"defaults"`
	}
	mustDecodeScheme("schemes/lithe.json", &file)
	return file.Defaults
}

// schemeVariants holds the syntax colors of each bundled scheme variant by its id, such as
// "idea-dark".
var schemeVariants = sync.OnceValue(func() map[string]map[string]string {
	variants := map[string]map[string]string{}
	for _, name := range []string{SchemeGitHub, SchemeOne, SchemeVSCode, SchemeIDEA} {
		var file struct {
			Themes []struct {
				ID     string            `json:"id"`
				Syntax map[string]string `json:"syntax"`
			} `json:"themes"`
		}
		mustDecodeScheme("schemes/"+name+".json", &file)
		for _, theme := range file.Themes {
			variants[theme.ID] = theme.Syntax
		}
	}
	return variants
})

func mustDecodeScheme(path string, into any) {
	data, err := schemeFiles.ReadFile(path)
	if err == nil {
		err = json.Unmarshal(data, into)
	}
	if err != nil {
		// The files are embedded and covered by tests; failing here is a build defect.
		panic("syntax: bundled scheme " + path + ": " + err.Error())
	}
}

// ThemeOptions are what an editor theme is built from.
type ThemeOptions struct {
	Dark bool
	// Scheme is one of the Scheme constants; anything else is SchemeLithe.
	Scheme         string
	ItalicComments bool
	// Foreground is the editor's text color from the workbench theme, "" for the palette's.
	Foreground string
	// Custom is an imported or user-defined theme, which overrides the rest.
	Custom *CustomTheme
}

// CustomTheme is a theme the user imported or defined.
type CustomTheme struct {
	Dark bool
	// Colors are its workbench colors; only "foreground" affects tokens.
	Colors map[string]string
	// Tokens style token names and palette roles; a name's style comes from its longest dotted
	// prefix present here, else from its role.
	Tokens map[string]CustomTokenStyle
}

// CustomTokenStyle is a CustomTheme's style for one token name or role.
type CustomTokenStyle struct {
	Foreground    string
	FontStyle     string
	SetsFontStyle bool
}

// tokenRoles maps theme token names to the palette role that colors them, in the previous
// editor's order. Lexical and semantic token names share it.
var tokenRoles = [][2]string{
	{"comment", "comment"}, {"comment.documentation", "comment"},
	{"keyword", "keyword"}, {"keyword.control", "keyword"}, {"keyword.directive", "keyword"},
	{"keyword.import", "keyword"}, {"keyword.return", "keyword"},
	{"string", "string"}, {"string.escape", "string"}, {"string.regexp", "regex"},
	{"string.regex", "regex"}, {"string.value", "string"}, {"string.key", "property"},
	{"number", "number"}, {"number.float", "number"}, {"number.hex", "number"},
	{"regexp", "regex"}, {"regexp.escape", "regex"}, {"regexp.escape.control", "regex"},
	{"identifier", "variable"}, {"variable.other", "variable"}, {"variable.predefined", "variable"},
	{"variable.readonly", "constant"}, {"type.identifier", "type"},
	{"function", "function"}, {"function.call", "function"}, {"function.builtin", "function"},
	{"function.method", "function"}, {"function.method.call", "function"},
	{"macro", "function"}, {"method", "function"},
	{"variable", "variable"}, {"parameter", "variable"}, {"variable.parameter", "variable"},
	{"constant", "constant"}, {"constant.builtin", "constant"}, {"enumMember", "constant"},
	{"boolean", "boolean"}, {"null", "null"}, {"keyword.other", "keyword"}, {"modifier", "keyword"},
	{"type", "type"}, {"typeParameter", "type"}, {"class", "type"}, {"enum", "type"},
	{"struct", "type"}, {"interface", "type"}, {"namespace", "type"}, {"module", "type"},
	{"module.builtin", "type"},
	{"property", "property"}, {"property.readonly", "constant"}, {"key", "property"},
	{"support.type.property-name", "property"},
	{"decorator", "attribute"}, {"annotation", "attribute"}, {"attribute", "attribute"},
	{"attribute.value", "string"}, {"attribute.value.number", "number"},
	{"attribute.value.unit", "number"}, {"attribute.value.hex", "number"},
	{"tag", "tag"}, {"metatag", "tag"}, {"metatag.content", "string"},
	{"attribute.name", "attribute"},
	{"delimiter", "punctuation"}, {"delimiter.bracket", "punctuation"}, {"bracket", "punctuation"},
	{"punctuation", "punctuation"}, {"operator", "operator"}, {"keyword.operator", "operator"},
	{"predefined", "constant"}, {"constructor", "function"}, {"event", "function"},
	{"label", "variable"}, {"parameter.readonly", "constant"},
	{"string.value.json", "string"}, {"string.key.json", "property"}, {"number.json", "number"},
	{"keyword.json", "boolean"},
}

// paletteRoles are the palette's names for roles it calls differently.
var paletteRoles = map[string]string{
	"function": "functionDeclaration", "attribute": "annotation", "regex": "string",
}

// schemeRoles are the scheme colors that stand in for palette roles a scheme does not name.
var schemeRoles = map[string]string{
	"annotation": "attribute", "documentationComment": "comment", "field": "property",
	"functionCall": "function", "functionDeclaration": "function", "parameter": "variable",
	"typeParameter": "type",
}

// styleRules are the font styles that do not depend on the palette: emphasis, and struck-out
// deprecated symbols of every semantic token type.
func styleRules(italicComments bool) []ThemeRule {
	rules := []ThemeRule{
		{Token: "emphasis", FontStyle: "italic", SetsFontStyle: true},
		{Token: "strong", FontStyle: "bold", SetsFontStyle: true},
	}
	for _, t := range SemanticTypes {
		font := "strikethrough"
		if t == "comment" && italicComments {
			font = "italic strikethrough"
		}
		rules = append(rules,
			ThemeRule{Token: t + ".deprecated", FontStyle: font, SetsFontStyle: true},
			ThemeRule{Token: t + ".readonly.deprecated", FontStyle: font, SetsFontStyle: true})
	}
	return rules
}

// BuildTheme builds the editor theme for opts from palette, the user's base syntax colors, the
// way the previous editor defined its Monaco themes, so that every token is colored as before.
func BuildTheme(opts ThemeOptions, palette Palette) *Theme {
	foreground := opts.Foreground
	if custom := opts.Custom; custom != nil {
		if custom.Dark != opts.Dark {
			foreground = ""
		}
		if fg := custom.Colors["foreground"]; fg != "" {
			foreground = fg
		}
		opts.Dark = custom.Dark
	}
	pick := func(c PaletteColor) string {
		if opts.Dark {
			return c.Dark
		}
		return c.Light
	}

	// syntax holds the colors by role and, once a scheme adds them, by token name.
	syntax := map[string]string{}
	for role, color := range palette {
		syntax[role] = pick(color)
	}
	appearance := "light"
	if opts.Dark {
		appearance = "dark"
	}
	if variant, ok := schemeVariants()[opts.Scheme+"-"+appearance]; ok {
		for role := range syntax {
			key := role
			if alias, ok := schemeRoles[role]; ok {
				key = alias
			}
			if color := variant[key]; color != "" {
				syntax[role] = color
			}
		}
		for token, color := range variant {
			syntax[token] = color
		}
	}

	tokens := make(map[string]string, len(syntax)+len(tokenRoles))
	for token, color := range syntax {
		tokens[token] = color
	}
	for _, pair := range tokenRoles {
		token, role := pair[0], pair[1]
		color, ok := syntax[token]
		if !ok {
			if native, ok := paletteRoles[role]; ok {
				role = native
			}
			color, ok = syntax[role]
		}
		if ok && color != "" {
			tokens[token] = color
		}
	}
	if opts.Scheme == SchemeIDEA {
		ideaOverrides(tokens, syntax, opts.Dark)
	}
	if opts.Custom != nil {
		if fg := opts.Custom.Colors["foreground"]; fg != "" {
			tokens[""] = fg
		}
	}

	base := monacoLightRules
	if opts.Dark {
		base = monacoDarkRules
	}
	rules := append([]ThemeRule(nil), base...)
	if foreground == "" {
		foreground = syntax["text"]
	}
	rules = append(rules, ThemeRule{Token: "", Foreground: foreground})
	for token, color := range tokens {
		rules = append(rules, ThemeRule{Token: token, Foreground: color})
	}
	comments := ""
	if opts.ItalicComments {
		comments = "italic"
	}
	rules = append(rules,
		ThemeRule{Token: "comment", FontStyle: comments, SetsFontStyle: true},
		ThemeRule{Token: "documentationComment", FontStyle: comments, SetsFontStyle: true})
	rules = append(rules, styleRules(opts.ItalicComments)...)
	if opts.Custom != nil && opts.Custom.Tokens != nil {
		rules = append(rules, customRules(opts.Custom.Tokens, tokens)...)
	}
	return NewTheme(rules)
}

// ideaOverrides resolves the IntelliJ IDEA scheme's colors for the tokens Monaco's base rules
// would otherwise color, as the IDEA scheme does in IntelliJ.
func ideaOverrides(tokens, syntax map[string]string, dark bool) {
	text := syntax["text"]
	// Keep Monaco's defaults for everything else, but resolve every inherited foreground
	// through this palette; otherwise a more specific base rule wins over IDEA
	// (keyword.flow, operator.swift, attribute.value.html, ...).
	tokens[""] = text
	base := monacoLightRules
	if dark {
		base = monacoDarkRules
	}
	for _, rule := range base {
		if rule.Foreground == "" || rule.Token == "invalid" {
			continue
		}
		if _, ok := tokens[rule.Token]; ok {
			continue
		}
		parent := rule.Token
		for {
			if _, ok := tokens[parent]; ok || parent == "" {
				break
			}
			parent = parent[:max(0, strings.LastIndexByte(parent, '.'))]
		}
		tokens[rule.Token] = tokens[parent]
	}
	set := func(role string, names ...string) {
		for _, name := range names {
			tokens[name] = syntax[role]
		}
	}
	// SQL's base rules color strings red, builtins magenta and operators slate.
	set("string", "string.sql")
	set("text", "operator.sql", "predefined.sql", "delimiter.sql", "delimiter.parenthesis.sql",
		"delimiter.square.sql")
	set("keyword", "operator.sql.word", "predefined.sql.keyword", "keyword.sql")
	set("number", "number.sql")
	set("comment", "comment.sql", "comment.quote.sql")
	// IntelliJ's YAML highlighter: keys are keywords, plain and block scalars text, quoted
	// scalars strings, comments documentation comments, anchors and tags identifiers. The
	// language suffix keeps Java and JSON as they are.
	set("keyword", "type.yaml")
	set("string", "string.yaml", "string.escape.yaml")
	set("text", "string.yaml.plain", "number.yaml", "keyword.yaml", "tag.yaml", "namespace.yaml",
		"operators.yaml")
	set("documentationComment", "comment.yaml")
	for _, kind := range []string{"float", "octal", "hex", "infinity", "nan", "date"} {
		set("text", "number."+kind+".yaml")
	}
	if !dark {
		// The light scheme colors YAML anchors itself instead of as identifiers.
		tokens["namespace.yaml"] = "#0000e6"
		tokens["tag.yaml"] = "#0000e6"
	}
	// Java method calls take the identifier color, and static methods have no color of their
	// own; declarations use the function declaration color. Lexical Java names stay neutral
	// until the language server classifies them.
	tokens["function.java"] = text
	for _, prefix := range []string{"method", "method.readonly", "method.deprecated", "method.readonly.deprecated"} {
		tokens[prefix] = text
		tokens[prefix+".declaration"] = syntax["functionDeclaration"]
		tokens[prefix+".static"] = text
		tokens[prefix+".declaration.static"] = text
	}
}

// customRules are a custom theme's token styles, applied after every built-in rule.
func customRules(custom map[string]CustomTokenStyle, tokens map[string]string) []ThemeRule {
	roles := make(map[string]string, len(tokenRoles))
	for _, pair := range tokenRoles {
		roles[pair[0]] = pair[1]
	}
	candidates := map[string]bool{}
	for token := range tokens {
		candidates[token] = true
	}
	for token := range custom {
		candidates[token] = true
	}
	for _, rule := range styleRules(false) {
		candidates[rule.Token] = true
	}
	var rules []ThemeRule
	for token := range candidates {
		key := token
		for key != "" {
			if _, ok := custom[key]; ok {
				break
			}
			key = key[:max(0, strings.LastIndexByte(key, '.'))]
		}
		parts := strings.Split(token, ".")
		method := parts[0] == "method"
		declaration := method && contains(parts, "declaration")
		static := method && contains(parts, "static")
		var style CustomTokenStyle
		var ok bool
		switch {
		case static && declaration:
			style, ok = custom["method.declaration.static"]
		case static:
			style, ok = custom["method.static"]
		case declaration:
			if style, ok = custom["method.declaration"]; !ok {
				style, ok = custom["functionDeclaration"]
			}
		default:
			if style, ok = custom[key]; !ok {
				if role, has := roles[token]; has {
					style, ok = custom[role]
				}
			}
		}
		if !ok {
			continue
		}
		rule := ThemeRule{Token: token, Foreground: style.Foreground}
		if style.SetsFontStyle {
			font := style.FontStyle
			if contains(parts, "deprecated") {
				font = strings.TrimSpace(font + " strikethrough")
			}
			rule.FontStyle, rule.SetsFontStyle = font, true
		}
		rules = append(rules, rule)
	}
	return rules
}

func contains(list []string, s string) bool {
	for _, v := range list {
		if v == s {
			return true
		}
	}
	return false
}
