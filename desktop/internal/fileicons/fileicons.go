// Package fileicons provides file, folder, symbol, and debugger breakpoint icons for the desktop
// client. File and folder names follow the classification rules of the previous macOS client.
// icons.go and icons_tree.go are generated from svg/ by
// scripts/desktop/generate-desktop-file-icons.sh; see NOTICE.
package fileicons

import (
	"strings"
	"unicode"

	"github.com/vivaui/viva/gfx"
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
	// kindJava identifies a Java source file.
	kindJava
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
	// kindTypeSymbol identifies a type symbol in outline and symbol-search lists.
	kindTypeSymbol
	// kindSymbol identifies a non-type symbol in outline and symbol-search lists.
	kindSymbol
	// kindSourceFolder identifies a directory explicitly marked as a source root.
	kindSourceFolder
	// kindResourceFolder identifies a directory explicitly marked as a resource root.
	kindResourceFolder
	// kindModuleFolder identifies a directory explicitly marked as a module.
	kindModuleFolder
	// kindPackageFolder identifies a package directory inside a known source root.
	kindPackageFolder
	// kindCount is the number of icon families and is not itself an icon family.
	kindCount
)

// kindIcons stores the light and optional dark icon for each file kind.
var kindIcons = [kindCount][2]*gfx.Icon{
	kindUnknown:        {&Unknown, &UnknownDark},
	kindFolder:         {&Folder, &FolderDark},
	kindExcludedFolder: {&ExcludeRoot, &ExcludeRootDark},
	kindSwift:          {&SwiftLang, &SwiftLangDark},
	kindJava:           {&Java, &JavaDark},
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
	kindTypeSymbol:     {&Class, &ClassDark},
	kindSymbol:         {&Variable, nil},
	kindSourceFolder:   {&SourceRoot, &SourceRootDark},
	kindResourceFolder: {&ResourcesRoot, &ResourcesRootDark},
	kindModuleFolder:   {&ModuleJava, &ModuleJavaDark},
	kindPackageFolder:  {&Package, &PackageDark},
}

// DirectoryMark identifies a directory role supplied explicitly by the user or by a
// plugin-imported build model. Directory names are not used to guess language layouts.
type DirectoryMark uint8

const (
	// MarkPlain represents an unmarked directory and is the zero value.
	MarkPlain DirectoryMark = iota
	// MarkSources marks a directory as a source root.
	MarkSources
	// MarkResources marks a directory as a resource root.
	MarkResources
	// MarkExcluded marks a directory as excluded from the project tree.
	MarkExcluded
	// MarkModule marks a directory as a module.
	MarkModule
	// MarkPackage marks a directory as a package.
	MarkPackage
)

// ForFile returns the icon for a file basename, using its dark variant when available.
func ForFile(name string, dark bool) gfx.Icon {
	return iconForKind(fileKind(name), dark)
}

// ForDirectory returns the icon for a directory name, using its dark variant when available.
func ForDirectory(name string, dark bool) gfx.Icon {
	return iconForKind(directoryKind(name), dark)
}

// TreeChevron returns the native project's original disclosure icon.
func TreeChevron(expanded, dark bool) gfx.Icon {
	if expanded {
		return iconForVariant(&TreechevronDown, &TreechevronDownDark, dark)
	}
	return iconForVariant(&TreechevronRight, &TreechevronRightDark, dark)
}

// ForDirectoryMark returns the icon for an explicit directory role, treating unknown marks as plain.
func ForDirectoryMark(mark DirectoryMark, dark bool) gfx.Icon {
	iconKind := kindFolder
	switch mark {
	case MarkSources:
		iconKind = kindSourceFolder
	case MarkResources:
		iconKind = kindResourceFolder
	case MarkExcluded:
		iconKind = kindExcludedFolder
	case MarkModule:
		iconKind = kindModuleFolder
	case MarkPackage:
		iconKind = kindPackageFolder
	}
	return iconForKind(iconKind, dark)
}

// ForSourceDirectory returns a package icon for a valid segment inside a known source root,
// unless the directory name identifies an excluded directory.
func ForSourceDirectory(name string, dark bool) gfx.Icon {
	return iconForKind(directoryKindInSourceRoot(name, true), dark)
}

// IsPackageSegmentName reports whether name starts with a Unicode letter, mark, or underscore and
// continues with Unicode letters, marks, numbers, or underscores. These categories preserve
// non-ASCII package names without accepting separators such as dots or hyphens.
func IsPackageSegmentName(name string) bool {
	first := true
	for _, character := range name {
		if first {
			if character != '_' && !unicode.IsLetter(character) && !unicode.IsMark(character) {
				return false
			}
			first = false
			continue
		}
		if character != '_' && !unicode.IsLetter(character) && !unicode.IsMark(character) && !unicode.IsNumber(character) {
			return false
		}
	}
	return !first
}

// ForType returns the icon for a type symbol in outline and symbol-search lists.
func ForType(dark bool) gfx.Icon {
	return iconForKind(kindTypeSymbol, dark)
}

// ForSymbol returns the icon for a non-type symbol, using the light asset because no dark variant exists.
func ForSymbol(dark bool) gfx.Icon {
	return iconForKind(kindSymbol, dark)
}

// ForBreakpoint returns a debugger gutter icon, preferring muted, disabled, verified, then set state.
func ForBreakpoint(enabled, verified, muted, dark bool) gfx.Icon {
	if muted {
		return iconForVariant(&DbMutedBreakpoint, &DbMutedBreakpointDark, dark)
	}
	if !enabled {
		return iconForVariant(&DbDisabledBreakpoint, &DbDisabledBreakpointDark, dark)
	}
	if verified {
		return iconForVariant(&DbVerifiedBreakpoint, &DbVerifiedBreakpointDark, dark)
	}
	return iconForVariant(&DbSetBreakpoint, &DbSetBreakpointDark, dark)
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
	case "java":
		return kindJava
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
	return directoryKindInSourceRoot(name, false)
}

// directoryKindInSourceRoot checks exclusions before considering package names inside source roots.
func directoryKindInSourceRoot(name string, insideSourceRoot bool) kind {
	switch strings.ToLower(name) {
	case "target", "build", "out", "bin", "dist", "node_modules", ".idea":
		return kindExcludedFolder
	}
	if insideSourceRoot && IsPackageSegmentName(name) {
		return kindPackageFolder
	}
	return kindFolder
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
func iconForKind(iconKind kind, dark bool) gfx.Icon {
	variants := kindIcons[iconKind]
	return iconForVariant(variants[0], variants[1], dark)
}

// iconForVariant returns a dark asset when available and otherwise preserves the light asset.
func iconForVariant(light, darkVariant *gfx.Icon, dark bool) gfx.Icon {
	if dark && darkVariant != nil {
		return *darkVariant
	}
	return *light
}
