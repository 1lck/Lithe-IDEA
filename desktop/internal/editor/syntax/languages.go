package syntax

// JavaRules are the rules of Java, the previous editor's Java classification: Java's comments,
// strings, numbers, keywords and declared functions carry a ".java" suffix, so that a scheme
// can style them apart from other languages, and support.function is not a function.
var JavaRules = []Rule{
	{Scope: "comment.block.documentation", Token: "comment.documentation.java", Enclosing: true},
	{Scope: "comment.block.javadoc", Token: "comment.documentation.java", Enclosing: true},
	{Scope: "comment.block", Token: "comment.block.java", Enclosing: true},
	{Scope: "comment", Token: "comment.line.java"},
	{Scope: "punctuation.definition.comment", Token: "comment.line.java"},
	{Scope: "constant.character.escape", Token: "string.escape.java"},
	{Scope: "storage.type.annotation", Token: "annotation"},
	{Scope: "string", Token: "string.java"},
	{Scope: "constant.numeric", Token: "number.java"},
	{Scope: "constant.language", Token: "keyword.java"},
	{Scope: "keyword", Token: "keyword.java"},
	{Scope: "storage", Token: "keyword.java"},
	{Scope: "entity.name.type", Token: "type.identifier"},
	{Scope: "entity.name.class", Token: "type.identifier"},
	{Scope: "entity.name.namespace", Token: "type.identifier"},
	{Scope: "support.class", Token: "type.identifier"},
	{Scope: "support.type", Token: "type.identifier"},
	{Scope: "entity.name.function", Token: "function.java"},
	{Scope: "variable", Token: "variable"},
	{Scope: "punctuation", Token: "delimiter"},
}

// codeRules are what the previous editor's Monarch tokenizers colored differently from its
// TextMate classification: a number is one number token, whatever its prefix, exponent or suffix
// are scoped, inside the number's scope or, as Go scopes them, beside it; a string's quotes are part of the string; an operator is a keyword when it is a
// word and a delimiter when it is a symbol; and a bracket is a delimiter. The word operators are
// enclosing because C++ names one keyword.operator.wordlike and, inside it, keyword.operator.and.
var codeRules = []Rule{
	{Scope: "constant.numeric", Token: "number", Enclosing: true},
	{Scope: "keyword.operator.expression", Token: "keyword", Enclosing: true},
	{Scope: "keyword.operator.wordlike", Token: "keyword", Enclosing: true},
	{Scope: "keyword.operator.functionlike", Token: "keyword", Enclosing: true},
	{Scope: "keyword.operator.new", Token: "keyword", Enclosing: true},
	{Scope: "keyword.operator.delete", Token: "keyword", Enclosing: true},
	{Scope: "keyword.operator.sizeof", Token: "keyword", Enclosing: true},
	{Scope: "keyword.operator.type.asserts", Token: "keyword", Enclosing: true},
	{Scope: "keyword.operator.type.modifier", Token: "keyword", Enclosing: true},
	{Scope: "keyword.other.unit", Token: "number"},
	{Scope: "keyword.operator.minus.exponent", Token: "number"},
	{Scope: "keyword.operator.plus.exponent", Token: "number"},
	{Scope: "keyword.operator.exponent", Token: "number"},
	{Scope: "punctuation.definition.string", Token: "string"},
	{Scope: "keyword.operator", Token: "delimiter"},
	{Scope: "storage.type.function.arrow", Token: "delimiter"},
	{Scope: "meta.brace.round", Token: "delimiter.parenthesis"},
	{Scope: "meta.brace.square", Token: "delimiter.square"},
}

// CodeRules are the rules of the bundled programming languages the previous editor colored
// with Monarch tokenizers: codeRules, then DefaultRules.
var CodeRules = WithDefaults(codeRules...)

// ScriptRules are the rules of JavaScript and TypeScript: a regular expression literal is one
// regexp token, as the previous editor colored it, whatever its parts are scoped; then CodeRules.
var ScriptRules = WithDefaults(append([]Rule{{Scope: "string.regexp", Token: "regexp", Enclosing: true}}, codeRules...)...)

// The rules of markup and configuration languages give their tokens the names the previous
// editor's Monarch tokenizers gave them, with the language's suffix, so that the color schemes
// written against those names, such as "tag.html" or "key.toml", style them the same.

// HTMLRules are the rules of HTML. Strings only occur in attribute values.
var HTMLRules = []Rule{
	{Scope: "comment", Token: "comment.html", Enclosing: true},
	{Scope: "meta.tag.metadata.doctype", Token: "metatag.html", Enclosing: true},
	{Scope: "entity.name.tag", Token: "tag.html"},
	{Scope: "punctuation.definition.tag", Token: "delimiter.html"},
	{Scope: "entity.other.attribute-name", Token: "attribute.name.html"},
	{Scope: "punctuation.separator.key-value", Token: "delimiter.html"},
	{Scope: "string", Token: "attribute.value.html"},
	{Scope: "constant.character.entity", Token: "string.escape.html"},
}

// XMLRules are the rules of XML. Strings only occur in attribute values and declarations;
// CDATA sections are plain text.
var XMLRules = []Rule{
	{Scope: "comment", Token: "comment.xml", Enclosing: true},
	{Scope: "keyword.other", Token: "metatag.xml"},
	{Scope: "entity.name.tag", Token: "tag.xml"},
	{Scope: "punctuation.definition.tag", Token: "delimiter.xml"},
	{Scope: "entity.other.attribute-name", Token: "attribute.name.xml"},
	{Scope: "variable.language.documentroot", Token: "attribute.name.xml"},
	{Scope: "string.quoted", Token: "attribute.value.xml"},
	{Scope: "constant.character.entity", Token: "string.escape.xml"},
	{Scope: "constant.character.parameter-entity", Token: "string.escape.xml"},
}

// CSSRules are the rules of CSS: selectors are tags, property names attribute names, and the
// parts of property values attribute values.
var CSSRules = []Rule{
	{Scope: "comment", Token: "comment.css", Enclosing: true},
	{Scope: "keyword.control.at-rule", Token: "keyword.css"},
	{Scope: "punctuation.definition.keyword", Token: "keyword.css"},
	{Scope: "keyword.other.important", Token: "keyword.css"},
	{Scope: "entity.name.tag", Token: "tag.css"},
	{Scope: "entity.other.attribute-name", Token: "tag.css"},
	{Scope: "entity.other.keyframe-offset", Token: "tag.css"},
	{Scope: "punctuation.definition.entity", Token: "tag.css"},
	{Scope: "support.type.property-name", Token: "attribute.name.css"},
	{Scope: "support.type.vendored.property-name", Token: "attribute.name.css"},
	{Scope: "variable.css", Token: "attribute.name.css"},
	{Scope: "constant.other.color.rgb-value", Token: "attribute.value.hex.css", Enclosing: true},
	{Scope: "constant.numeric", Token: "attribute.value.number.css"},
	{Scope: "keyword.other.unit", Token: "attribute.value.unit.css"},
	{Scope: "string", Token: "string.css"},
	{Scope: "support.constant", Token: "attribute.value.css"},
	{Scope: "support.function", Token: "attribute.value.css"},
	{Scope: "variable", Token: "attribute.value.css"},
	{Scope: "punctuation.section.function", Token: "delimiter.parenthesis.css"},
	{Scope: "punctuation.definition.parameters", Token: "delimiter.parenthesis.css"},
	{Scope: "punctuation.section", Token: "delimiter.bracket.css"},
	{Scope: "punctuation", Token: "delimiter.css"},
	{Scope: "keyword.operator", Token: "delimiter.css"},
}

// JSONRules are the rules of JSON and JSON with comments, named as the previous editor's JSON
// tokenizer named them.
var JSONRules = []Rule{
	{Scope: "comment.block.documentation", Token: "comment.documentation", Enclosing: true},
	{Scope: "comment.block", Token: "comment.block.json", Enclosing: true},
	{Scope: "comment", Token: "comment.line.json", Enclosing: true},
	{Scope: "support.type.property-name", Token: "string.key.json", Enclosing: true},
	{Scope: "string", Token: "string.value.json", Enclosing: true},
	{Scope: "constant.numeric", Token: "number.json"},
	{Scope: "constant.language", Token: "keyword.json"},
	{Scope: "punctuation.definition.dictionary", Token: "delimiter.bracket.json"},
	{Scope: "punctuation.definition.array", Token: "delimiter.array.json"},
	{Scope: "punctuation.separator.dictionary.key-value", Token: "delimiter.colon.json"},
	{Scope: "punctuation.separator", Token: "delimiter.comma.json"},
}

// YAMLRules are the rules of YAML: keys are types, as in the previous editor, and plain
// scalars strings with a ".plain" suffix that the IntelliJ scheme styles apart from quoted
// ones.
var YAMLRules = []Rule{
	{Scope: "comment", Token: "comment.yaml", Enclosing: true},
	{Scope: "entity.name.tag", Token: "type.yaml"},
	{Scope: "meta.map.key", Token: "type.yaml", Enclosing: true},
	{Scope: "keyword.other.directive", Token: "meta.directive.yaml"},
	{Scope: "punctuation.definition.directive", Token: "meta.directive.yaml"},
	{Scope: "meta.directive", Token: "meta.directive.yaml"},
	{Scope: "entity.other.document.begin", Token: "operators.directivesEnd.yaml"},
	{Scope: "entity.other.document.end", Token: "operators.documentEnd.yaml"},
	{Scope: "keyword.control.flow.anchor", Token: "namespace.yaml"},
	{Scope: "keyword.control.flow.alias", Token: "namespace.yaml"},
	{Scope: "punctuation.definition.anchor", Token: "namespace.yaml"},
	{Scope: "punctuation.definition.alias", Token: "namespace.yaml"},
	{Scope: "variable.other.anchor", Token: "namespace.yaml"},
	{Scope: "variable.other.alias", Token: "namespace.yaml"},
	{Scope: "storage.type.tag", Token: "tag.yaml"},
	{Scope: "storage.type.tag-handle", Token: "tag.yaml"},
	{Scope: "support.type.tag-prefix", Token: "tag.yaml"},
	{Scope: "punctuation.definition.tag", Token: "tag.yaml"},
	{Scope: "constant.language", Token: "keyword.yaml"},
	{Scope: "constant.numeric", Token: "number.yaml"},
	{Scope: "constant.character.escape", Token: "string.escape.yaml"},
	{Scope: "string.unquoted.plain", Token: "string.yaml.plain"},
	{Scope: "string.unquoted.block", Token: "string.yaml.plain"},
	{Scope: "string", Token: "string.yaml"},
	{Scope: "punctuation.definition.mapping", Token: "delimiter.bracket.yaml"},
	{Scope: "punctuation.definition.sequence", Token: "delimiter.square.yaml"},
	{Scope: "punctuation.separator.mapping", Token: "delimiter.comma.yaml"},
	{Scope: "punctuation.separator.sequence", Token: "delimiter.comma.yaml"},
	{Scope: "punctuation.separator", Token: "operators.yaml"},
	{Scope: "punctuation.definition.block.sequence", Token: "operators.yaml"},
	{Scope: "punctuation.definition.map.key", Token: "operators.yaml"},
	{Scope: "keyword.control.flow.block-scalar", Token: "operators.yaml"},
	{Scope: "storage.modifier.chomping-indicator", Token: "operators.yaml"},
	{Scope: "constant.numeric.indentation-indicator", Token: "operators.yaml"},
}

// MarkdownRules are the rules of Markdown: a heading's marker is a keyword and its text a
// heading, inline code a variable, code blocks strings, and a link's text a link.
var MarkdownRules = []Rule{
	{Scope: "comment", Token: "comment.md", Enclosing: true},
	{Scope: "punctuation.definition.heading", Token: "keyword.md"},
	{Scope: "markup.heading", Token: "keyword.md.heading"},
	{Scope: "punctuation.definition.quote", Token: "comment.md"},
	{Scope: "punctuation.definition.list", Token: "keyword.md"},
	{Scope: "meta.separator", Token: "keyword.md"},
	{Scope: "punctuation.separator.table", Token: "keyword.table.md"},
	{Scope: "markup.inline.raw", Token: "variable.md"},
	{Scope: "markup.fenced_code", Token: "string.md"},
	{Scope: "markup.raw", Token: "string.md"},
	{Scope: "markup.bold", Token: "strong"},
	{Scope: "markup.italic", Token: "emphasis"},
	{Scope: "string.other.link", Token: "md.link"},
	{Scope: "markup.underline.link", Token: "string.link.md"},
	{Scope: "constant.other.reference.link", Token: "string.link.md"},
	{Scope: "punctuation.definition.link", Token: "string.link.md"},
	{Scope: "punctuation.definition.metadata", Token: "string.link.md"},
	{Scope: "constant.character.escape", Token: "string.escape.md"},
	{Scope: "punctuation.definition.begin.frontmatter", Token: "keyword.md"},
	{Scope: "punctuation.definition.end.frontmatter", Token: "keyword.md"},
}

// INIRules are the rules of INI and properties files: sections are metatags and keys keys.
var INIRules = []Rule{
	{Scope: "comment", Token: "comment.ini", Enclosing: true},
	{Scope: "entity.name.section", Token: "metatag.ini"},
	{Scope: "punctuation.definition.entity", Token: "metatag.ini"},
	{Scope: "keyword.other.definition", Token: "key.ini"},
	{Scope: "punctuation.separator.key-value", Token: "delimiter.ini"},
	{Scope: "constant.character.escape", Token: "string.escape.ini"},
	{Scope: "string", Token: "string.ini"},
}

// TOMLRules are the rules of TOML: table headers are types and keys keys.
var TOMLRules = []Rule{
	{Scope: "comment", Token: "comment.toml", Enclosing: true},
	{Scope: "support.type.property-name.table", Token: "type.toml"},
	{Scope: "support.type.property-name.array", Token: "type.toml"},
	{Scope: "punctuation.definition.table.toml", Token: "type.toml"},
	{Scope: "punctuation.definition.array.table", Token: "type.toml"},
	{Scope: "meta.table.toml", Token: "type.toml"},
	{Scope: "meta.array.table", Token: "type.toml"},
	{Scope: "support.type.property-name", Token: "key.toml"},
	{Scope: "constant.character.escape", Token: "string.escape.toml"},
	{Scope: "string", Token: "string.toml"},
	{Scope: "constant.language", Token: "keyword.toml"},
	{Scope: "constant.numeric", Token: "number.toml"},
	{Scope: "constant.other.time", Token: "number.toml"},
}

// DotenvRules are the rules of .env files: names are keys and values strings.
var DotenvRules = []Rule{
	{Scope: "comment", Token: "comment.dotenv", Enclosing: true},
	{Scope: "keyword.key.export", Token: "keyword.dotenv"},
	{Scope: "variable.key", Token: "key.dotenv"},
	{Scope: "keyword.operator.assignment", Token: "delimiter.dotenv"},
	{Scope: "keyword.interpolation", Token: "delimiter.bracket.dotenv"},
	{Scope: "variable.interpolation", Token: "variable.dotenv"},
	{Scope: "constant.character.escape", Token: "string.escape.dotenv"},
	{Scope: "string", Token: "string.dotenv"},
	{Scope: "property.value", Token: "string.dotenv"},
}

// languageAliases maps Lithe language IDs to the bundled language that colors them, the
// previous editor's mapping to Monaco's languages. IDs that map to themselves are left out.
var languageAliases = map[string]string{
	"angular":          "html",
	"bash":             "shell",
	"batch":            "bat",
	"jupyter-notebook": "json",
	"make":             "makefile",
	"objc":             "objective-c",
	"properties":       "ini",
	"protobuf":         "proto",
	"ql":               "sql",
	"rescript":         "javascript",
	"rmarkdown":        "markdown",
	"sass":             "scss",
	"solidity":         "sol",
	"svelte":           "html",
	"systemrdl":        "plaintext",
	"terraform":        "hcl",
	"tla":              "plaintext",
	"vue":              "html",
}

// The delimiters most languages share.
var (
	cComments    = Comments{Line: "//", Block: Pair{"/*", "*/"}}
	hashComments = Comments{Line: "#"}
	markupBlock  = Comments{Block: Pair{"<!--", "-->"}}

	cBrackets      = []Pair{{"{", "}"}, {"[", "]"}, {"(", ")"}}
	markupBrackets = []Pair{{"<!--", "-->"}, {"<", ">"}, {"{", "}"}, {"(", ")"}}
	cAutoClosing   = []Pair{{"{", "}"}, {"[", "]"}, {"(", ")"}, {`"`, `"`}, {"'", "'"}}
	bracketClosing = []Pair{{"{", "}"}, {"[", "]"}, {"(", ")"}}
	markupClosing  = []Pair{{"{", "}"}, {"[", "]"}, {"(", ")"}, {`"`, `"`}, {"'", "'"}, {"<", ">"}}
	scriptClosing  = []Pair{{"{", "}"}, {"[", "]"}, {"(", ")"}, {`"`, `"`}, {"'", "'"}, {"`", "`"}}
	jsonBrackets   = []Pair{{"{", "}"}, {"[", "]"}}
	jsonClosing    = []Pair{{"{", "}"}, {"[", "]"}, {`"`, `"`}}
)

// bundledLanguages are the languages the editor knows without plugins: the previous editor's
// Monaco languages with their file associations, and the basic associations it added. File
// names and prefixes are tried in this order, before any extension.
var bundledLanguages = []Language{
	{ID: "java", Scope: "source.java", Extensions: []string{".java", ".jav"}, Rules: JavaRules,
		Comments: cComments, Brackets: cBrackets, AutoClosing: cAutoClosing},
	{ID: "makefile", Scope: "source.makefile", Extensions: []string{".mk", ".mak"},
		FileNames: []string{"makefile", "gnumakefile"}, FilePrefixes: []string{"makefile."},
		Comments: hashComments, Brackets: cBrackets, AutoClosing: bracketClosing},
	{ID: "cmake", Extensions: []string{".cmake"}, FileNames: []string{"cmakelists.txt"},
		Comments: hashComments, Brackets: cBrackets, AutoClosing: bracketClosing},
	{ID: "groovy", Extensions: []string{".groovy", ".gradle"}, FileNames: []string{"jenkinsfile"},
		Comments: cComments, Brackets: cBrackets, AutoClosing: bracketClosing},
	{ID: "kotlin", Extensions: []string{".kt", ".kts", ".gradle.kts"},
		Comments: cComments, Brackets: cBrackets, AutoClosing: cAutoClosing},
	{ID: "powershell", Extensions: []string{".ps1", ".psm1", ".psd1"},
		Comments: Comments{Line: "#", Block: Pair{"<#", "#>"}}, Brackets: cBrackets, AutoClosing: cAutoClosing},
	{ID: "bat", Extensions: []string{".bat", ".cmd"},
		Comments: Comments{Line: "REM"}, Brackets: cBrackets, AutoClosing: cAutoClosing},
	{ID: "shell", Extensions: []string{".sh", ".bash", ".zsh"},
		FileNames: []string{".bashrc", ".zshrc", ".bash_profile", ".zprofile", ".profile"},
		Comments:  hashComments, Brackets: cBrackets, AutoClosing: cAutoClosing},
	{ID: "dotenv", Scope: "source.dotenv", Rules: DotenvRules, FileNames: []string{".env"}, FilePrefixes: []string{".env."},
		Comments: hashComments, Brackets: cBrackets, AutoClosing: cAutoClosing},
	{ID: "dockerfile", Extensions: []string{".dockerfile"}, FileNames: []string{"dockerfile", "containerfile"},
		FilePrefixes: []string{"dockerfile.", "containerfile."},
		Comments:     hashComments, Brackets: cBrackets, AutoClosing: cAutoClosing},
	{ID: "c", Scope: "source.c", Rules: CodeRules, Extensions: []string{".c", ".h"}, Comments: cComments, Brackets: cBrackets, AutoClosing: cAutoClosing},
	{ID: "cpp", Scope: "source.cpp", Rules: CodeRules, Extensions: []string{".cpp", ".cc", ".cxx", ".c++", ".hpp", ".hh", ".hxx", ".h++", ".inl", ".ipp"},
		Comments: cComments, Brackets: cBrackets, AutoClosing: cAutoClosing},
	{ID: "csharp", Extensions: []string{".cs", ".csx", ".cake"}, Comments: cComments, Brackets: cBrackets, AutoClosing: cAutoClosing},
	{ID: "css", Scope: "source.css", Rules: CSSRules, Extensions: []string{".css"}, Comments: Comments{Block: Pair{"/*", "*/"}}, Brackets: cBrackets, AutoClosing: cAutoClosing},
	{ID: "dart", Extensions: []string{".dart"}, Comments: cComments, Brackets: cBrackets, AutoClosing: cAutoClosing},
	{ID: "elixir", Extensions: []string{".ex", ".exs"}, Comments: hashComments, Brackets: cBrackets, AutoClosing: cAutoClosing},
	{ID: "go", Scope: "source.go", Rules: CodeRules, Extensions: []string{".go"}, Comments: cComments, Brackets: cBrackets,
		AutoClosing: scriptClosing},
	{ID: "graphql", Extensions: []string{".graphql", ".gql"}, Comments: hashComments, Brackets: cBrackets, AutoClosing: cAutoClosing},
	{ID: "hcl", Extensions: []string{".tf", ".tfvars", ".hcl"},
		Comments: Comments{Line: "#", Block: Pair{"/*", "*/"}}, Brackets: cBrackets, AutoClosing: cAutoClosing},
	{ID: "html", Scope: "text.html.basic", Rules: HTMLRules, Extensions: []string{".html", ".htm", ".shtml", ".xhtml", ".mdoc", ".jsp", ".asp", ".aspx", ".jshtm"},
		Comments: markupBlock, Brackets: markupBrackets, AutoClosing: markupClosing},
	{ID: "ini", Scope: "source.ini", Rules: INIRules, Extensions: []string{".ini", ".properties", ".gitconfig"},
		FileNames: []string{".gitconfig", ".editorconfig"}, Comments: hashComments, Brackets: cBrackets, AutoClosing: cAutoClosing},
	{ID: "javascript", Scope: "source.js", Rules: ScriptRules, Extensions: []string{".js", ".es6", ".mjs", ".cjs"},
		FileNames: []string{"jakefile"}, Comments: cComments, Brackets: cBrackets, AutoClosing: scriptClosing},
	{ID: "javascriptreact", Scope: "source.js.jsx", Rules: ScriptRules, Extensions: []string{".jsx"},
		Comments: cComments, Brackets: cBrackets, AutoClosing: scriptClosing},
	{ID: "jsonc", Scope: "source.json.comments", Rules: JSONRules,
		Extensions:   []string{".jsonc", ".code-workspace", ".jshintrc", ".jscsrc", ".eslintrc", ".babelrc"},
		FileNames:    []string{"tsconfig.json", "jsconfig.json", ".eslintrc.json", "devcontainer.json", ".devcontainer.json"},
		FilePrefixes: []string{"tsconfig.", "jsconfig."},
		Comments:     cComments, Brackets: jsonBrackets, AutoClosing: jsonClosing},
	{ID: "json", Scope: "source.json", Rules: JSONRules, Extensions: []string{".json", ".bowerrc", ".har"},
		Comments: cComments, Brackets: jsonBrackets, AutoClosing: jsonClosing},
	{ID: "less", Extensions: []string{".less"}, Comments: cComments, Brackets: cBrackets, AutoClosing: cAutoClosing},
	{ID: "lua", Extensions: []string{".lua"}, Comments: Comments{Line: "--", Block: Pair{"--[[", "]]"}},
		Brackets: cBrackets, AutoClosing: cAutoClosing},
	{ID: "markdown", Scope: "text.html.markdown", Rules: MarkdownRules, Extensions: []string{".md", ".markdown", ".mdown", ".mkdn", ".mkd", ".mdwn", ".mdtxt", ".mdtext"},
		Comments: markupBlock, Brackets: cBrackets, AutoClosing: []Pair{{"{", "}"}, {"[", "]"}, {"(", ")"}, {"<", ">"}}},
	{ID: "objective-c", Extensions: []string{".m"}, Comments: cComments, Brackets: cBrackets, AutoClosing: cAutoClosing},
	{ID: "php", Extensions: []string{".php", ".php4", ".php5", ".phtml", ".ctp"}, Comments: cComments, Brackets: cBrackets, AutoClosing: cAutoClosing},
	{ID: "proto", Extensions: []string{".proto"}, Comments: cComments, Brackets: cBrackets, AutoClosing: cAutoClosing},
	{ID: "python", Extensions: []string{".py", ".rpy", ".pyw", ".cpy", ".gyp", ".gypi"},
		Comments: Comments{Line: "#", Block: Pair{"'''", "'''"}}, Brackets: cBrackets, AutoClosing: cAutoClosing},
	{ID: "r", Extensions: []string{".r", ".rhistory", ".rmd", ".rprofile", ".rt"}, Comments: hashComments, Brackets: cBrackets, AutoClosing: cAutoClosing},
	{ID: "ruby", Extensions: []string{".rb", ".rbx", ".rjs", ".gemspec", ".pp"}, FileNames: []string{"rakefile", "gemfile"},
		Comments: Comments{Line: "#", Block: Pair{"=begin", "=end"}}, Brackets: cBrackets, AutoClosing: cAutoClosing},
	{ID: "rust", Scope: "source.rust", Rules: CodeRules, Extensions: []string{".rs", ".rlib"}, Comments: cComments, Brackets: cBrackets,
		AutoClosing: []Pair{{"{", "}"}, {"[", "]"}, {"(", ")"}, {`"`, `"`}}},
	{ID: "scala", Extensions: []string{".scala", ".sc", ".sbt"}, Comments: cComments, Brackets: cBrackets, AutoClosing: cAutoClosing},
	{ID: "scheme", Extensions: []string{".scm", ".ss", ".sch", ".rkt"},
		Comments: Comments{Line: ";", Block: Pair{"#|", "|#"}}, Brackets: cBrackets, AutoClosing: cAutoClosing},
	{ID: "scss", Extensions: []string{".scss"}, Comments: cComments, Brackets: cBrackets, AutoClosing: cAutoClosing},
	{ID: "sol", Extensions: []string{".sol"}, Comments: cComments, Brackets: cBrackets, AutoClosing: cAutoClosing},
	{ID: "sql", Extensions: []string{".sql"}, Comments: Comments{Line: "--", Block: Pair{"/*", "*/"}}, Brackets: cBrackets, AutoClosing: cAutoClosing},
	{ID: "swift", Extensions: []string{".swift"}, Comments: cComments, Brackets: cBrackets, AutoClosing: cAutoClosing},
	{ID: "typescript", Scope: "source.ts", Rules: ScriptRules, Extensions: []string{".ts", ".cts", ".mts"},
		Comments: cComments, Brackets: cBrackets, AutoClosing: scriptClosing},
	{ID: "typescriptreact", Scope: "source.tsx", Rules: ScriptRules, Extensions: []string{".tsx"},
		Comments: cComments, Brackets: cBrackets, AutoClosing: scriptClosing},
	{ID: "xml", Scope: "text.xml", Rules: XMLRules, Extensions: []string{".xml", ".xsd", ".dtd", ".ascx", ".csproj", ".config", ".props", ".targets",
		".wxi", ".wxl", ".wxs", ".xaml", ".svg", ".svgz", ".opf", ".xslt", ".xsl"},
		Comments: markupBlock, Brackets: markupBrackets, AutoClosing: markupClosing},
	{ID: "yaml", Scope: "source.yaml", Rules: YAMLRules, Extensions: []string{".yaml", ".yml"}, Comments: hashComments, Brackets: cBrackets, AutoClosing: cAutoClosing},
	{ID: "zig", Extensions: []string{".zig", ".zon"}, Comments: Comments{Line: "//"}, Brackets: cBrackets, AutoClosing: cAutoClosing},
	{ID: "toml", Scope: "source.toml", Rules: TOMLRules, Extensions: []string{".toml"}, Comments: hashComments, Brackets: cBrackets, AutoClosing: cAutoClosing},
	{ID: "plaintext", Extensions: []string{".txt"}},
}
