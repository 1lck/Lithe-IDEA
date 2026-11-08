package syntax

import (
	"embed"
	"fmt"
	"reflect"
	"slices"
	"strings"
	"sync"

	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/textmate"
)

//go:embed grammars/*.tmLanguage.json
var grammarFiles embed.FS

// bundledGrammars are the embedded grammars by scope name. Adding a language's grammar is a
// file in grammars/, its license in NOTICE.txt, an entry here and the Scope of its Language.
//
// The bundled languages are the common ones; plugins add the others, and may replace these,
// with grammars of their own (API-25).
var bundledGrammars = map[string]string{
	"source.c":                  "grammars/c.tmLanguage.json",
	"source.cpp":                "grammars/cpp.tmLanguage.json",
	"source.cpp.embedded.macro": "grammars/cpp.embedded.macro.tmLanguage.json",
	"source.css":                "grammars/css.tmLanguage.json",
	"source.dotenv":             "grammars/dotenv.tmLanguage.json",
	"source.go":                 "grammars/go.tmLanguage.json",
	"source.ini":                "grammars/ini.tmLanguage.json",
	"source.java":               "grammars/java.tmLanguage.json",
	"source.js":                 "grammars/JavaScript.tmLanguage.json",
	"source.js.jsx":             "grammars/JavaScriptReact.tmLanguage.json",
	"source.json":               "grammars/JSON.tmLanguage.json",
	"source.json.comments":      "grammars/JSONC.tmLanguage.json",
	"source.makefile":           "grammars/make.tmLanguage.json",
	"source.rust":               "grammars/rust.tmLanguage.json",
	"source.toml":               "grammars/toml.tmLanguage.json",
	"source.ts":                 "grammars/TypeScript.tmLanguage.json",
	"source.tsx":                "grammars/TypeScriptReact.tmLanguage.json",
	"source.yaml":               "grammars/yaml.tmLanguage.json",
	"source.yaml.1.0":           "grammars/yaml-1.0.tmLanguage.json",
	"source.yaml.1.1":           "grammars/yaml-1.1.tmLanguage.json",
	"source.yaml.1.2":           "grammars/yaml-1.2.tmLanguage.json",
	"source.yaml.1.3":           "grammars/yaml-1.3.tmLanguage.json",
	"source.yaml.embedded":      "grammars/yaml-embedded.tmLanguage.json",
	"text.html.basic":           "grammars/html.tmLanguage.json",
	"text.html.markdown":        "grammars/markdown.tmLanguage.json",
	"text.xml":                  "grammars/xml.tmLanguage.json",
}

// hasBundledGrammar and loadBundledGrammar are the library of every Registry: a bundled
// grammar is parsed the first time a language needs it, or tokenizing first reaches an
// include of it.
func hasBundledGrammar(scope string) bool {
	_, ok := bundledGrammars[scope]
	return ok
}

func loadBundledGrammar(scope string) *textmate.RawGrammar {
	path, ok := bundledGrammars[scope]
	if !ok {
		return nil
	}
	data, err := grammarFiles.ReadFile(path)
	if err != nil {
		panic("syntax: bundled grammar " + path + ": " + err.Error())
	}
	raw, err := textmate.ParseGrammar(data)
	if err != nil {
		// The files are embedded and covered by tests; failing here is a build defect.
		panic("syntax: bundled grammar " + path + ": " + err.Error())
	}
	return raw
}

// Pair is an opening and a closing delimiter, such as "{" and "}".
type Pair struct{ Open, Close string }

// Comments are a language's comment delimiters. Either may be empty.
type Comments struct {
	Line  string
	Block Pair
}

// Language is what the editor knows about one language: the files that are in it, the grammar
// that tokenizes it and how its tokens are named, and the delimiters editing commands use.
// A Language is not changed once a Registry holds it.
type Language struct {
	ID string
	// Scope is the scope name of the grammar that tokenizes the language, or "" when the
	// language has none and is shown as plain text.
	Scope string
	// Extensions are lower-case file name suffixes, with their dot: ".java", ".gradle.kts".
	Extensions []string
	// FileNames are lower-case base names, such as "makefile".
	FileNames []string
	// FilePrefixes are lower-case base name prefixes, such as ".env.".
	FilePrefixes []string
	// Rules name the grammar's tokens; nil means DefaultRules.
	Rules       []Rule
	Comments    Comments
	Brackets    []Pair
	AutoClosing []Pair
}

func (l *Language) rules() []Rule {
	if l.Rules == nil {
		return DefaultRules
	}
	return l.Rules
}

// PluginLanguage is a language a plugin contributes. Its fields replace those of the bundled
// language its ID resolves to, if any, when they are set; the rest are inherited.
type PluginLanguage struct {
	ID string
	// Extensions are file name suffixes, with or without their dot, in any case.
	Extensions []string
	// FileNames are base names, in any case.
	FileNames []string
	// Grammar is a TextMate grammar in JSON. Without one the language uses the grammar of the
	// bundled language its ID resolves to, or none.
	Grammar     []byte
	Rules       []Rule
	Comments    Comments
	Brackets    []Pair
	AutoClosing []Pair
}

// PluginLanguageError is a plugin language that could not be registered, and why.
type PluginLanguageError struct {
	ID  string
	Err error
}

// Syntax is a language's compiled grammar together with how its tokens are named: what a
// Highlighter tokenizes with. It is safe for concurrent use.
type Syntax struct {
	language *Language
	grammar  *textmate.Grammar
	names    *classifier
}

// Language is the language the Syntax is for.
func (s *Syntax) Language() *Language { return s.language }

// Grammar is the compiled grammar.
func (s *Syntax) Grammar() *textmate.Grammar { return s.grammar }

// Registry holds the bundled languages and those plugins contribute, picks the language of a
// file, and compiles the Syntax of a language once. It is safe for concurrent use.
type Registry struct {
	grammars *textmate.Registry

	mu sync.Mutex
	// plugins are the plugin languages by ID, and pluginOrder their IDs in the order given.
	plugins     map[string]*pluginEntry
	pluginOrder []string
	// scopeOwners is, for each scope a plugin grammar was added under, the ID of the language
	// that added it.
	scopeOwners map[string]string
	syntaxes    map[string]*Syntax
	// classifiers are the classifiers of the languages by ID, shared by a language's Syntax and
	// the languages that embed it.
	classifiers map[string]*classifier
	version     uint64
}

type pluginEntry struct {
	source   PluginLanguage
	language *Language
}

// NewRegistry returns a registry of the bundled languages.
func NewRegistry() *Registry {
	return &Registry{
		grammars:    textmate.NewLazyRegistry(hasBundledGrammar, loadBundledGrammar),
		plugins:     map[string]*pluginEntry{},
		scopeOwners: map[string]string{},
		syntaxes:    map[string]*Syntax{},
		classifiers: map[string]*classifier{},
	}
}

// Version changes whenever plugin languages change what a language resolves to; a view that
// cached Syntaxes or languages asks for them again.
func (r *Registry) Version() uint64 {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.version
}

// CanonicalID maps a Lithe language ID to the ID of the bundled language that colors it, as the
// previous editor did: "bash" is "shell", "vue" is "html", "text" is "plaintext". An ID it does
// not know is returned unchanged.
func CanonicalID(id string) string {
	if id == "text" {
		return "plaintext"
	}
	if canonical, ok := languageAliases[id]; ok {
		return canonical
	}
	return id
}

// Language returns the language of id: a plugin language with that ID, or else the bundled
// language id resolves to.
func (r *Registry) Language(id string) (*Language, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.languageLocked(id)
}

func (r *Registry) languageLocked(id string) (*Language, bool) {
	if entry, ok := r.plugins[id]; ok {
		return entry.language, true
	}
	if entry, ok := r.plugins[CanonicalID(id)]; ok {
		return entry.language, true
	}
	return bundledLanguage(CanonicalID(id))
}

func bundledLanguage(id string) (*Language, bool) {
	index, ok := bundledIndex()[id]
	if !ok {
		return nil, false
	}
	return &bundledLanguages[index], true
}

var bundledIndex = sync.OnceValue(func() map[string]int {
	index := make(map[string]int, len(bundledLanguages))
	for i, language := range bundledLanguages {
		index[language.ID] = i
	}
	return index
})

// bundledExtensions are the extensions of the bundled languages, longest first.
var bundledExtensions = sync.OnceValue(func() []extensionEntry {
	var list []extensionEntry
	for i, language := range bundledLanguages {
		for _, extension := range language.Extensions {
			list = append(list, extensionEntry{extension, i})
		}
	}
	slices.SortStableFunc(list, func(a, b extensionEntry) int { return len(b.extension) - len(a.extension) })
	return list
})

type extensionEntry struct {
	extension string
	language  int
}

// ForPath returns the language of a file by its name, case-insensitively, with "/" or "\" as
// path separators. Plugin languages come first, by exact name and then by longest extension;
// then the bundled ones, by exact name or name prefix in table order and then by longest
// extension.
func (r *Registry) ForPath(path string) (*Language, bool) {
	name := strings.ToLower(path[strings.LastIndexAny(path, `/\`)+1:])
	if name == "" {
		return nil, false
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if language := r.pluginForName(name); language != nil {
		return language, true
	}
	for i := range bundledLanguages {
		language := &bundledLanguages[i]
		if slices.Contains(language.FileNames, name) {
			return r.resolveBundledLocked(language), true
		}
		for _, prefix := range language.FilePrefixes {
			if strings.HasPrefix(name, prefix) {
				return r.resolveBundledLocked(language), true
			}
		}
	}
	for _, entry := range bundledExtensions() {
		if strings.HasSuffix(name, entry.extension) {
			return r.resolveBundledLocked(&bundledLanguages[entry.language]), true
		}
	}
	return nil, false
}

// resolveBundledLocked returns the plugin language that replaces a bundled one, or the
// bundled one.
func (r *Registry) resolveBundledLocked(language *Language) *Language {
	if entry, ok := r.plugins[language.ID]; ok {
		return entry.language
	}
	return language
}

func (r *Registry) pluginForName(name string) *Language {
	for _, id := range r.pluginOrder {
		language := r.plugins[id].language
		if slices.Contains(language.FileNames, name) {
			return language
		}
	}
	var best *Language
	bestLength := 0
	for _, id := range r.pluginOrder {
		language := r.plugins[id].language
		for _, extension := range language.Extensions {
			if len(extension) > bestLength && strings.HasSuffix(name, extension) {
				best, bestLength = language, len(extension)
			}
		}
	}
	return best
}

// Syntax returns the compiled Syntax of the language of id, or nil when the language is
// unknown or has no grammar. The grammar's patterns compile when a tokenizer first needs them.
func (r *Registry) Syntax(id string) *Syntax {
	r.mu.Lock()
	defer r.mu.Unlock()
	language, ok := r.languageLocked(id)
	if !ok || language.Scope == "" {
		return nil
	}
	if syntax, ok := r.syntaxes[language.ID]; ok {
		return syntax
	}
	grammar, ok := r.grammars.Grammar(language.Scope)
	if !ok {
		return nil
	}
	syntax := &Syntax{language: language, grammar: grammar, names: r.classifierLocked(language)}
	r.syntaxes[language.ID] = syntax
	return syntax
}

func (r *Registry) classifierLocked(language *Language) *classifier {
	if c, ok := r.classifiers[language.ID]; ok {
		return c
	}
	c := newClassifier(language.ID, language.rules(), r.embeddedClassifier)
	r.classifiers[language.ID] = c
	return c
}

// embeddedIDs are the IDs grammars embed languages under that are not Lithe language IDs.
var embeddedIDs = map[string]string{
	"frontmatter": "yaml", "js": "javascript", "shellscript": "shell", "ts": "typescript", "tsx": "typescriptreact",
}

// embeddedClassifier returns the classifier of the language a grammar embeds under scope, or
// nil when scope embeds none. A classifier calls it while it names a token, from the UI or a
// highlighter's worker, never with r.mu held.
func (r *Registry) embeddedClassifier(scope string) *classifier {
	id, ok := strings.CutPrefix(scope, "meta.embedded.block.")
	if !ok {
		id, ok = strings.CutPrefix(scope, "meta.embedded.line.")
	}
	if !ok {
		id, ok = strings.CutPrefix(scope, "meta.embedded.expression.")
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	var language *Language
	if ok {
		if alias, ok := embeddedIDs[id]; ok {
			id = alias
		}
		language, _ = r.languageLocked(id)
	} else {
		language = r.languageOfScopeLocked(scope)
	}
	if language == nil {
		return nil
	}
	return r.classifierLocked(language)
}

// languageOfScopeLocked returns the language whose grammar has the root scope scope, or nil.
func (r *Registry) languageOfScopeLocked(scope string) *Language {
	for _, id := range r.pluginOrder {
		if language := r.plugins[id].language; language.Scope == scope {
			return language
		}
	}
	if i, ok := bundledScopes()[scope]; ok {
		return r.resolveBundledLocked(&bundledLanguages[i])
	}
	return nil
}

// bundledScopes are the indexes of the bundled languages by the scope of their grammar.
var bundledScopes = sync.OnceValue(func() map[string]int {
	index := map[string]int{}
	for i, language := range bundledLanguages {
		if language.Scope != "" {
			index[language.Scope] = i
		}
	}
	return index
})

// SetPluginLanguages replaces the plugin languages with list. A language whose grammar does
// not parse is not registered and is reported in failed; languages registered before and not
// in list are reported in removed. Languages that did not change keep their Syntax.
func (r *Registry) SetPluginLanguages(list []PluginLanguage) (failed []PluginLanguageError, removed []string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	next := make(map[string]PluginLanguage, len(list))
	var order []string
	for _, language := range list {
		if language.ID == "" {
			continue
		}
		if _, seen := next[language.ID]; !seen {
			order = append(order, language.ID)
		}
		next[language.ID] = language
	}
	changed := false
	for _, id := range r.pluginOrder {
		if _, ok := next[id]; !ok {
			r.removePluginLocked(id)
			removed = append(removed, id)
			changed = true
		}
	}
	kept := order[:0:0]
	for _, id := range order {
		source := next[id]
		if entry, ok := r.plugins[id]; ok && reflect.DeepEqual(entry.source, source) {
			kept = append(kept, id)
			continue
		}
		changed = true
		if _, ok := r.plugins[id]; ok {
			r.removePluginLocked(id)
		}
		language, err := r.addPluginLocked(source)
		if err != nil {
			failed = append(failed, PluginLanguageError{ID: id, Err: err})
			continue
		}
		r.plugins[id] = &pluginEntry{source: clonePlugin(source), language: language}
		kept = append(kept, id)
	}
	r.pluginOrder = kept
	if changed {
		clear(r.syntaxes)
		clear(r.classifiers)
		r.version++
	}
	return failed, removed
}

func (r *Registry) removePluginLocked(id string) {
	delete(r.plugins, id)
	for scope, owner := range r.scopeOwners {
		if owner == id {
			delete(r.scopeOwners, scope)
			// A bundled grammar of the same scope is loaded again when next needed.
			r.grammars.Remove(scope)
		}
	}
}

func (r *Registry) addPluginLocked(source PluginLanguage) (*Language, error) {
	language := &Language{ID: source.ID}
	if base, ok := bundledLanguage(CanonicalID(source.ID)); ok {
		*language = *base
		language.ID = source.ID
	}
	if source.Grammar != nil {
		raw, err := textmate.ParseGrammar(source.Grammar)
		if err != nil {
			return nil, err
		}
		if owner, ok := r.scopeOwners[raw.ScopeName]; ok && owner != source.ID {
			return nil, fmt.Errorf("grammar scope %s is already registered by %s", raw.ScopeName, owner)
		}
		r.grammars.Add(raw)
		r.scopeOwners[raw.ScopeName] = source.ID
		language.Scope = raw.ScopeName
		// A plugin grammar's scopes follow its own conventions; the bundled language's
		// rules were written for the bundled grammar.
		language.Rules = nil
	}
	if len(source.Extensions) > 0 || len(source.FileNames) > 0 {
		language.Extensions = make([]string, 0, len(source.Extensions))
		for _, extension := range source.Extensions {
			if extension = strings.ToLower(extension); extension != "" {
				if extension[0] != '.' {
					extension = "." + extension
				}
				language.Extensions = append(language.Extensions, extension)
			}
		}
		language.FileNames = make([]string, 0, len(source.FileNames))
		for _, name := range source.FileNames {
			if name != "" {
				language.FileNames = append(language.FileNames, strings.ToLower(name))
			}
		}
		language.FilePrefixes = nil
	}
	if source.Rules != nil {
		language.Rules = slices.Clone(source.Rules)
	}
	if source.Comments != (Comments{}) {
		language.Comments = source.Comments
	}
	if source.Brackets != nil {
		language.Brackets = slices.Clone(source.Brackets)
	}
	if source.AutoClosing != nil {
		language.AutoClosing = slices.Clone(source.AutoClosing)
	}
	return language, nil
}

// clonePlugin copies the slices of a plugin language, so that the caller may reuse its own.
func clonePlugin(source PluginLanguage) PluginLanguage {
	source.Extensions = slices.Clone(source.Extensions)
	source.FileNames = slices.Clone(source.FileNames)
	source.Grammar = slices.Clone(source.Grammar)
	source.Rules = slices.Clone(source.Rules)
	source.Brackets = slices.Clone(source.Brackets)
	source.AutoClosing = slices.Clone(source.AutoClosing)
	return source
}
