// Package fileicons is the file-type and folder icons of the project tree, the editor tabs and
// the Git views, chosen by name the way the previous Lithe macOS client chose them. icons.go is
// generated from svg/ by scripts/desktop/generate-desktop-file-icons.sh; see NOTICE.
package fileicons

import (
	"strings"

	"github.com/vivaui/viva/ui"
)

// kind identifies a file or directory icon family.
type kind uint8

const (
	// kindUnknown identifies a file without a recognized type and is the zero value.
	kindUnknown kind = iota
	// kindFolder identifies a directory.
	kindFolder
	// kindExcludedFolder identifies a directory excluded from the project tree.
	kindExcludedFolder
	// kindSwift identifies a Swift file.
	kindSwift
	// kindKotlin identifies a Kotlin file.
	kindKotlin
	// kindRust identifies a Rust file.
	kindRust
	// kindGoSource identifies a Go source or module file.
	kindGoSource
	// kindPython identifies a Python file.
	kindPython
	// kindRuby identifies a Ruby file.
	kindRuby
	// kindScala identifies a Scala file.
	kindScala
	// kindGroovy identifies a Groovy file.
	kindGroovy
	// kindPHP identifies a PHP file.
	kindPHP
	// kindCSource identifies a C or Objective-C source file.
	kindCSource
	// kindCHeader identifies a C-family header file.
	kindCHeader
	// kindCpp identifies a C++ or Objective-C++ source file.
	kindCpp
	// kindCSharp identifies a C# source file.
	kindCSharp
	// kindShell identifies a shell script.
	kindShell
	// kindPowerShell identifies a PowerShell script.
	kindPowerShell
	// kindJavaScript identifies a JavaScript or TypeScript file.
	kindJavaScript
	// kindCSS identifies a CSS-family stylesheet.
	kindCSS
	// kindHTML identifies an HTML-family document.
	kindHTML
	// kindXML identifies an XML-family document.
	kindXML
	// kindProperties identifies a properties or environment file.
	kindProperties
	// kindEditorConfig identifies an EditorConfig file.
	kindEditorConfig
	// kindYAML identifies a YAML file.
	kindYAML
	// kindJSON identifies a JSON-family file.
	kindJSON
	// kindTOML identifies a TOML file.
	kindTOML
	// kindCSV identifies a delimited text file.
	kindCSV
	// kindDocker identifies a Docker or Compose file.
	kindDocker
	// kindDatabase identifies a database or SQL file.
	kindDatabase
	// kindGitignore identifies a Git or Docker ignore file.
	kindGitignore
	// kindNodePackage identifies a Node.js package manifest.
	kindNodePackage
	// kindLock identifies a dependency lock file.
	kindLock
	// kindMakefile identifies a Makefile.
	kindMakefile
	// kindMarkdown identifies a Markdown-family document.
	kindMarkdown
	// kindReadme identifies a README file.
	kindReadme
	// kindLicense identifies a license or copyright file.
	kindLicense
	// kindText identifies a plain text file.
	kindText
	// kindI18n identifies a localization strings file.
	kindI18n
	// kindDocument identifies an office document.
	kindDocument
	// kindImage identifies an image file.
	kindImage
	// kindBinary identifies an archive or binary file.
	kindBinary
	// kindCount is the number of icon families and is not itself an icon family.
	kindCount
)

// kindIcons stores the light and optional dark icon for each file kind.
var kindIcons = [kindCount][2]*ui.Icon{
	kindUnknown:        {&Unknown, &UnknownDark},
	kindFolder:         {&Folder, &FolderDark},
	kindExcludedFolder: {&ExcludeRoot, &ExcludeRootDark},
	kindSwift:          {&SwiftLang, &SwiftLangDark},
	kindKotlin:         {&Kotlin, nil},
	kindRust:           {&Rust, nil},
	kindGoSource:       {&Go, nil},
	kindPython:         {&Python, nil},
	kindRuby:           {&Ruby, nil},
	kindScala:          {&Scala, nil},
	kindGroovy:         {&Groovy, &GroovyDark},
	kindPHP:            {&Php, nil},
	kindCSource:        {&C, &CDark},
	kindCHeader:        {&H, &HDark},
	kindCpp:            {&Cpp, &CppDark},
	kindCSharp:         {&Csharp, &CsharpDark},
	kindShell:          {&Shell, &ShellDark},
	kindPowerShell:     {&Powershell, &PowershellDark},
	kindJavaScript:     {&JavaScript, &JavaScriptDark},
	kindCSS:            {&Css, &CssDark},
	kindHTML:           {&Html, &HtmlDark},
	kindXML:            {&Xml, &XmlDark},
	kindProperties:     {&Properties, &PropertiesDark},
	kindEditorConfig:   {&EditorConfig, &EditorConfigDark},
	kindYAML:           {&Yaml, &YamlDark},
	kindJSON:           {&Json, &JsonDark},
	kindTOML:           {&Toml, &TomlDark},
	kindCSV:            {&Csv, &CsvDark},
	kindDocker:         {&Docker, &DockerDark},
	kindDatabase:       {&Sql, &SqlDark},
	kindGitignore:      {&Gitignore, nil},
	kindNodePackage:    {&Nodejs, &NodejsDark},
	kindLock:           {&Lock, &LockDark},
	kindMakefile:       {&Makefile, &MakefileDark},
	kindMarkdown:       {&Markdown, &MarkdownDark},
	kindReadme:         {&Readme, &ReadmeDark},
	kindLicense:        {&License, &LicenseDark},
	kindText:           {&Text, &TextDark},
	kindI18n:           {&I18n, &I18nDark},
	kindDocument:       {&Custom, &CustomDark},
	kindImage:          {&Image, &ImageDark},
	kindBinary:         {&Archive, &ArchiveDark},
}

// ForFile returns the icon for a file basename, using its dark variant when available.
func ForFile(name string, dark bool) ui.Icon {
	return iconForKind(fileKind(name), dark)
}

// ForDirectory returns the icon for a directory name, using its dark variant when available.
func ForDirectory(name string, dark bool) ui.Icon {
	return iconForKind(directoryKind(name), dark)
}

// fileKind selects the icon family for a file basename.
func fileKind(name string) kind {
	lowerName := strings.ToLower(name)
	if lowerName == ".gitignore" || lowerName == ".gitattributes" || lowerName == ".dockerignore" {
		return kindGitignore
	}
	if lowerName == "package.json" {
		return kindNodePackage
	}
	if lowerName == "package-lock.json" || lowerName == "npm-shrinkwrap.json" ||
		lowerName == "pnpm-lock.yaml" || lowerName == "bun.lockb" {
		return kindLock
	}
	if lowerName == "go.mod" || lowerName == "go.sum" || lowerName == "go.work" || lowerName == "go.work.sum" {
		return kindGoSource
	}
	if lowerName == "makefile" || lowerName == "gnumakefile" {
		return kindMakefile
	}
	stem, ext := splitExt(lowerName)
	if stem == "readme" {
		return kindReadme
	}
	if stem == "license" || stem == "licence" || stem == "copying" || strings.HasPrefix(stem, "license-") {
		return kindLicense
	}
	if lowerName == ".editorconfig" {
		return kindEditorConfig
	}
	if lowerName == "dockerfile" || strings.HasPrefix(lowerName, "dockerfile.") ||
		lowerName == "compose.yaml" || lowerName == "compose.yml" ||
		lowerName == "docker-compose.yaml" || lowerName == "docker-compose.yml" {
		return kindDocker
	}
	// Environment files need a name check because ".env.local" has the extension "local".
	if lowerName == ".env" || strings.HasPrefix(lowerName, ".env.") {
		return kindProperties
	}
	switch ext {
	case "lock":
		return kindLock
	case "mk", "mak":
		return kindMakefile
	case "swift":
		return kindSwift
	case "kt", "kts":
		return kindKotlin
	case "rs":
		return kindRust
	case "go":
		return kindGoSource
	case "py", "pyw", "pyi":
		return kindPython
	case "rb", "rake", "gemspec":
		return kindRuby
	case "scala", "sc":
		return kindScala
	case "groovy":
		return kindGroovy
	case "php", "phtml":
		return kindPHP
	case "c", "m":
		return kindCSource
	case "h", "hh", "hpp", "hxx":
		return kindCHeader
	case "cpp", "cc", "cxx", "mm":
		return kindCpp
	case "cs":
		return kindCSharp
	case "js", "jsx", "mjs", "cjs", "ts", "tsx":
		return kindJavaScript
	case "sh", "zsh", "bash", "fish":
		return kindShell
	case "ps1", "psm1", "psd1", "ps1xml", "psc1", "pssc":
		return kindPowerShell
	case "css", "scss", "sass", "less":
		return kindCSS
	case "html", "htm", "xhtml", "vue", "svelte":
		return kindHTML
	case "toml":
		return kindTOML
	case "xml", "xsd", "wsdl":
		return kindXML
	case "properties", "ini", "cfg", "conf", "env":
		return kindProperties
	case "yml", "yaml":
		return kindYAML
	case "json", "json5", "jsonl", "jsonlines", "ndjson", "ldjson":
		return kindJSON
	case "db", "sqlite", "sqlite3", "sql", "mv":
		return kindDatabase
	case "md", "markdown", "rst", "adoc":
		return kindMarkdown
	case "txt", "log":
		return kindText
	case "strings":
		return kindI18n
	case "doc", "docx", "ppt", "pptx":
		return kindDocument
	case "csv", "tsv":
		return kindCSV
	case "png", "jpg", "jpeg", "gif", "webp", "svg", "ico", "bmp", "tiff", "wbmp":
		return kindImage
	case "zip", "gz", "tar", "so", "dylib", "dll", "icns", "pdf", "woff", "woff2", "ttf", "otf":
		return kindBinary
	default:
		return kindUnknown
	}
}

// directoryKind selects the icon family for a directory name.
func directoryKind(name string) kind {
	switch strings.ToLower(name) {
	case "target", "build", "out", "bin", "dist", "node_modules", ".idea":
		return kindExcludedFolder
	default:
		return kindFolder
	}
}

// splitExt separates a base name at its last dot, as NSString does: a name whose only dot
// leads it (".bashrc") or that ends in a dot has no extension, and its stem is the whole name.
func splitExt(name string) (stem, ext string) {
	dot := strings.LastIndexByte(name, '.')
	if dot <= 0 || dot == len(name)-1 {
		return name, ""
	}
	return name[:dot], name[dot+1:]
}

// iconForKind returns a kind's light icon unless a requested dark variant exists.
func iconForKind(iconKind kind, dark bool) ui.Icon {
	variants := kindIcons[iconKind]
	if dark && variants[1] != nil {
		return *variants[1]
	}
	return *variants[0]
}
