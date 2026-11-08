package textmate

import (
	"encoding/json"
	"fmt"
	"maps"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"

	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/textmate/internal/regexp2"
)

// RawGrammar is a TextMate grammar as its JSON file has it. Only what tokenizing reads is
// kept; injections are not supported.
//
// A grammar is read the way the kernel validates a plugin's grammar (plugins/grammar.rs in
// Lithe-core-rust), so that the rules the editor runs are the rules the kernel checked: keys
// match exactly, where encoding/json alone would also take a key that differs in case, such as
// a "Patterns" the kernel ignores as a note; a repeated key takes its last value; and keys the
// engine does not read are notes.
type RawGrammar struct {
	ScopeName  string
	Name       string
	Patterns   []*RawRule
	Repository map[string]*RawRule
}

// RawRule is one rule of a RawGrammar.
type RawRule struct {
	Include             string
	Name                string
	ContentName         string
	Match               string
	Begin               string
	End                 string
	While               string
	Captures            RawCaptures
	BeginCaptures       RawCaptures
	EndCaptures         RawCaptures
	WhileCaptures       RawCaptures
	Patterns            []*RawRule
	Repository          map[string]*RawRule
	ApplyEndPatternLast flag
}

// MaxCaptureGroup is the highest capture group a rule may name, as the kernel bounds it. The
// compiler sizes a pattern's capture table by its highest group, so a rule for a higher group
// is ignored rather than allowed to make that table large.
const MaxCaptureGroup = 4096

// RawCaptures are the rules of a rule's capture groups by group number. Grammars write them
// as an object keyed by the number; an array is read by position.
type RawCaptures map[int]*RawRule

// flag is a boolean a grammar may write as true, 1 or "1".
type flag bool

// ParseGrammar reads a TextMate grammar in JSON.
//
// The JSON is decoded once into generic values and the grammar is then read from them by
// exact key, which is both faster than decoding into the structs and free of encoding/json's
// case-insensitive key matching. A value of the wrong type is an error, as decoding into the
// structs would make it; a pattern or capture written as null is left out.
func ParseGrammar(data []byte) (*RawGrammar, error) {
	var value any
	if err := json.Unmarshal(data, &value); err != nil {
		return nil, fmt.Errorf("textmate grammar: %w", err)
	}
	object, ok := value.(map[string]any)
	if !ok {
		return nil, fmt.Errorf("textmate grammar: not a JSON object")
	}
	var d decoder
	grammar := &RawGrammar{
		ScopeName:  d.string("scopeName", object["scopeName"]),
		Name:       d.string("name", object["name"]),
		Patterns:   d.patterns("patterns", object["patterns"]),
		Repository: d.repository("repository", object["repository"]),
	}
	if d.err != nil {
		return nil, fmt.Errorf("textmate grammar: %w", d.err)
	}
	if grammar.ScopeName == "" {
		return nil, fmt.Errorf("textmate grammar: no scopeName")
	}
	return grammar, nil
}

// decoder reads a grammar from its generic JSON values, keeping the first error it meets.
type decoder struct {
	// path is where the value being read sits, for errors; it is formatted only on failure.
	path []step
	err  error
}

// step is one key of a path, with the index into its array when index is not negative.
type step struct {
	key   string
	index int
}

func (d *decoder) push(key string, index int) { d.path = append(d.path, step{key, index}) }

func (d *decoder) pop() { d.path = d.path[:len(d.path)-1] }

// fail records that the value at key, or at the current path when key is empty, is not want.
func (d *decoder) fail(key, want string) {
	if d.err != nil {
		return
	}
	steps := d.path
	if key != "" {
		steps = append(steps[:len(steps):len(steps)], step{key, -1})
	}
	var path strings.Builder
	for _, s := range steps {
		if path.Len() > 0 {
			path.WriteByte('.')
		}
		path.WriteString(s.key)
		if s.index >= 0 {
			fmt.Fprintf(&path, "[%d]", s.index)
		}
	}
	d.err = fmt.Errorf("%s: want %s", path.String(), want)
}

// string reads the string value at key; null is "".
func (d *decoder) string(key string, value any) string {
	if value == nil {
		return ""
	}
	text, ok := value.(string)
	if !ok {
		d.fail(key, "a string")
	}
	return text
}

// readFlag reads true, a non-zero number, or a string other than "", "0" and "false" as true.
func readFlag(value any) flag {
	switch value := value.(type) {
	case bool:
		return flag(value)
	case float64:
		return value != 0
	case string:
		return value != "" && value != "0" && value != "false"
	}
	return false
}

// rule reads the rule at key, or at key[index] when index is not negative.
func (d *decoder) rule(value any, key string, index int) *RawRule {
	if value == nil {
		return nil
	}
	object, ok := value.(map[string]any)
	if !ok {
		d.push(key, index)
		d.fail("", "an object")
		d.pop()
		return nil
	}
	d.push(key, index)
	// One pass over the rule's few keys is cheaper than a lookup for each key a rule may have.
	rule := &RawRule{}
	for name, entry := range object {
		switch name {
		case "include":
			rule.Include = d.string(name, entry)
		case "name":
			rule.Name = d.string(name, entry)
		case "contentName":
			rule.ContentName = d.string(name, entry)
		case "match":
			rule.Match = d.string(name, entry)
		case "begin":
			rule.Begin = d.string(name, entry)
		case "end":
			rule.End = d.string(name, entry)
		case "while":
			rule.While = d.string(name, entry)
		case "captures":
			rule.Captures = d.captures(name, entry)
		case "beginCaptures":
			rule.BeginCaptures = d.captures(name, entry)
		case "endCaptures":
			rule.EndCaptures = d.captures(name, entry)
		case "whileCaptures":
			rule.WhileCaptures = d.captures(name, entry)
		case "patterns":
			rule.Patterns = d.patterns(name, entry)
		case "repository":
			rule.Repository = d.repository(name, entry)
		case "applyEndPatternLast":
			rule.ApplyEndPatternLast = readFlag(entry)
		}
	}
	d.pop()
	return rule
}

// patterns reads the list of rules at key, leaving out those written as null.
func (d *decoder) patterns(key string, value any) []*RawRule {
	if value == nil {
		return nil
	}
	list, ok := value.([]any)
	if !ok {
		d.fail(key, "an array")
		return nil
	}
	rules := make([]*RawRule, 0, len(list))
	for i, item := range list {
		if rule := d.rule(item, key, i); rule != nil {
			rules = append(rules, rule)
		}
	}
	return rules
}

// repository reads the rules by name at key.
func (d *decoder) repository(key string, value any) map[string]*RawRule {
	if value == nil {
		return nil
	}
	entries, ok := value.(map[string]any)
	if !ok {
		d.fail(key, "an object")
		return nil
	}
	repository := make(map[string]*RawRule, len(entries))
	d.push(key, -1)
	for name, entry := range entries {
		if rule := d.rule(entry, name, -1); rule != nil {
			repository[name] = rule
		}
	}
	d.pop()
	return repository
}

// captures reads captures written as an object or as an array. An object key is a group
// number as strconv.Atoi reads it, with an optional sign; a key that is not a number or is
// negative is a note, such as vscode-textmate's own location field. When keys such as "1" and
// "01" name the same group, the one written as the number itself wins, and otherwise the key
// that sorts last, so the result never depends on the order keys are visited in. A rule
// written as null, and a rule for a group above MaxCaptureGroup, are left out.
func (d *decoder) captures(key string, value any) RawCaptures {
	if value == nil {
		return nil
	}
	captures := RawCaptures{}
	switch groups := value.(type) {
	case []any:
		for i, item := range groups[:min(len(groups), MaxCaptureGroup+1)] {
			if rule := d.rule(item, key, i); rule != nil {
				captures[i] = rule
			}
		}
	case map[string]any:
		type group struct {
			key       string
			number    int
			canonical bool
		}
		keys := make([]group, 0, len(groups))
		for name := range groups {
			number, err := strconv.Atoi(name)
			if err != nil || number < 0 || number > MaxCaptureGroup {
				continue
			}
			keys = append(keys, group{name, number, strconv.Itoa(number) == name})
		}
		// The key that wins a group is read last.
		sort.Slice(keys, func(i, j int) bool {
			a, b := keys[i], keys[j]
			if a.canonical != b.canonical {
				return b.canonical
			}
			return a.key < b.key
		})
		d.push(key, -1)
		for _, g := range keys {
			if rule := d.rule(groups[g.key], g.key, -1); rule != nil {
				captures[g.number] = rule
			} else {
				delete(captures, g.number)
			}
		}
		d.pop()
	default:
		d.fail(key, "an object or an array")
		return nil
	}
	return captures
}

// Registry holds the grammars one editor knows, so that a grammar can include another by its
// scope name. It is safe for concurrent use.
//
// A grammar is compiled when it is first asked for, and a grammar it includes only when
// tokenizing first reaches the include, so that opening Markdown does not read the grammar of
// every language a fenced block could hold. A compiled grammar resolves its includes against
// the grammars registered when it was compiled: adding or removing a grammar never changes
// what a grammar compiled before runs, and Grammar compiles anew after such a change.
type Registry struct {
	mu sync.Mutex
	// added are the grammars Add registered by scope, in front of the library's. The map is
	// replaced, never changed, so compiled grammars can keep the one they were compiled with.
	added    map[string]*RawGrammar
	compiled map[string]*Grammar
	library  *library
}

// library is the grammars a lazy registry loads, each read once and kept.
type library struct {
	has  func(scope string) bool
	load func(scope string) *RawGrammar

	mu     sync.Mutex
	loaded map[string]*RawGrammar
}

// get returns the grammar of scope, loading it on first use.
func (l *library) get(scope string) *RawGrammar {
	l.mu.Lock()
	defer l.mu.Unlock()
	if raw, ok := l.loaded[scope]; ok {
		return raw
	}
	var raw *RawGrammar
	if l.has(scope) {
		raw = l.load(scope)
	}
	l.loaded[scope] = raw
	return raw
}

// NewRegistry returns an empty registry.
func NewRegistry() *Registry { return NewLazyRegistry(nil, nil) }

// NewLazyRegistry returns a registry that also knows the grammars of a library: has says,
// without reading anything, whether load has a grammar for a scope, and load reads it, at most
// once for each scope. Grammars added take precedence over the library's. Both functions may
// be called from any goroutine and must not call the registry; nil functions make an empty
// library.
func NewLazyRegistry(has func(scope string) bool, load func(scope string) *RawGrammar) *Registry {
	r := &Registry{added: map[string]*RawGrammar{}, compiled: map[string]*Grammar{}}
	if has != nil && load != nil {
		r.library = &library{has: has, load: load, loaded: map[string]*RawGrammar{}}
	}
	return r
}

// Add registers grammar under its scope name, in place of a grammar registered there before.
// Grammars compiled before keep working with what they could include; Grammar compiles them
// anew.
func (r *Registry) Add(grammar *RawGrammar) {
	r.mu.Lock()
	defer r.mu.Unlock()
	added := maps.Clone(r.added)
	added[grammar.ScopeName] = grammar
	r.added = added
	clear(r.compiled)
}

// Remove unregisters the grammar Add registered for scope, which leaves the library's grammar
// of scope, if any.
func (r *Registry) Remove(scope string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	added := maps.Clone(r.added)
	delete(added, scope)
	r.added = added
	clear(r.compiled)
}

// Grammar returns the compiled grammar of scope, compiling it on first use, or false when no
// grammar has that scope. The grammars it includes are compiled when tokenizing reaches them.
func (r *Registry) Grammar(scope string) (*Grammar, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if g, ok := r.compiled[scope]; ok {
		return g, true
	}
	source := &grammarSource{added: r.added, library: r.library}
	raw := source.raw(scope)
	if raw == nil {
		return nil, false
	}
	g := compileGrammar(raw, source)
	r.compiled[scope] = g
	return g, true
}

// grammarSource is what one compiled grammar resolves includes of other grammars against: the
// grammars added when it was compiled, then the library.
type grammarSource struct {
	added   map[string]*RawGrammar
	library *library
}

// has says whether a grammar has scope, without reading it.
func (s *grammarSource) has(scope string) bool {
	if _, ok := s.added[scope]; ok {
		return true
	}
	return s.library != nil && s.library.has(scope)
}

// raw returns the grammar of scope, or nil when there is none.
func (s *grammarSource) raw(scope string) *RawGrammar {
	if raw, ok := s.added[scope]; ok {
		return raw
	}
	if s.library == nil {
		return nil
	}
	return s.library.get(scope)
}

// Grammar is a compiled TextMate grammar. Its rules are compiled once: those of the grammars
// it includes when tokenizing first reaches the include, and patterns to regular expressions
// on first use. It is safe for concurrent use.
type Grammar struct {
	scopeName string
	// rules are the grammar's rules by id; rules[0] is unused. Compiling an included grammar
	// publishes a longer list that starts with the same rules, so a reader loads the list for
	// each use rather than keep it.
	rules atomic.Pointer[[]*rule]
	root  int

	// compileMu guards compiler, which compiles included grammars when they are reached.
	compileMu sync.Mutex
	compiler  *compiler

	scopesMu sync.Mutex
	scopes   map[scopeKey]*ScopeStack
	rootStk  *ScopeStack
	initial  *StateStack

	errorsMu sync.Mutex
	errors   []error
}

// rule returns the rule with id.
func (g *Grammar) rule(id int) *rule { return (*g.rules.Load())[id] }

// ScopeName is the grammar's scope, such as source.java.
func (g *Grammar) ScopeName() string { return g.scopeName }

// PatternErrors are the patterns of the grammar that have failed to compile so far, which
// never match. At most maxPatternErrors are kept.
func (g *Grammar) PatternErrors() []error {
	g.errorsMu.Lock()
	defer g.errorsMu.Unlock()
	return append([]error(nil), g.errors...)
}

const maxPatternErrors = 64

func (g *Grammar) patternFailed(err error) {
	g.errorsMu.Lock()
	defer g.errorsMu.Unlock()
	if len(g.errors) < maxPatternErrors {
		g.errors = append(g.errors, err)
	}
}

// ruleKind is what a rule does when it matches.
type ruleKind uint8

const (
	// includeOnlyRule only groups patterns: the grammar's root and a capture's patterns.
	includeOnlyRule ruleKind = iota
	// matchRule names what one pattern matches.
	matchRule
	// beginEndRule spans from its begin pattern to its end pattern.
	beginEndRule
	// beginWhileRule spans from its begin pattern for as long as each following line starts
	// with its while pattern.
	beginWhileRule
	// externalRule stands in a rule's patterns for an include of a grammar not compiled yet.
	// Collecting the patterns compiles that grammar and collects the rule the include names.
	externalRule
)

// Scanner ids that stand for a rule's own end and while patterns rather than a rule.
const (
	endRuleID   = -1
	whileRuleID = -2
)

// rule is one compiled rule.
type rule struct {
	id                                                  int
	kind                                                ruleKind
	name, contentName                                   name
	match, begin, end, while                            *pattern
	captures, beginCaptures, endCaptures, whileCaptures []*captureRule
	// patterns are the ids of the rules the rule's content is scanned with.
	patterns []int
	// missingPatterns says some of the rule's patterns include what does not exist.
	missingPatterns     bool
	applyEndPatternLast bool

	// include is what an externalRule includes, as a grammar wrote it, and base is the rule
	// $base names in the included grammar.
	include string
	base    *RawRule
	// target is the rule an externalRule's include names once compiled, or -1 when it names
	// nothing; 0 means not compiled yet. Grammar.compileMu guards it.
	target int

	scanOnce sync.Once
	// entries are the patterns that start something inside the rule, in priority order.
	entries []entry

	resolvedMu sync.Mutex
	// resolved are the rule's end or while pattern with back-references to its begin
	// replaced, by the text that replaced them.
	resolved map[string]*pattern
}

// captureRule is what a capture group of a pattern is.
type captureRule struct {
	name, contentName name
	// retokenize is the rule whose patterns tokenize the captured text again, or 0.
	retokenize int
}

// entry is one pattern of a scanner, with the rule that matching it starts.
type entry struct {
	rule int
	pat  *pattern
}

// name is a rule's scope name, which may take text from the match: $1 or ${1:/downcase}.
type name struct {
	text     string
	captures bool
}

var captureReference = regexp.MustCompile(`\$(\d+)|\$\{(\d+):/(downcase|upcase)\}`)

func newName(text string) name {
	return name{text: text, captures: captureReference.MatchString(text)}
}

// resolve returns the scope name for a match of text with the groups caps, in rune indices.
func (n name) resolve(text []rune, caps []span) string {
	if !n.captures {
		return n.text
	}
	return captureReference.ReplaceAllStringFunc(n.text, func(reference string) string {
		match := captureReference.FindStringSubmatch(reference)
		number := match[1]
		if number == "" {
			number = match[2]
		}
		index, _ := strconv.Atoi(number)
		if index >= len(caps) {
			return reference
		}
		value := strings.TrimLeft(string(text[caps[index].start:caps[index].end]), ".")
		switch match[3] {
		case "downcase":
			return strings.ToLower(value)
		case "upcase":
			return strings.ToUpper(value)
		}
		return value
	})
}

// pattern is one regular expression of a grammar, compiled on first use.
type pattern struct {
	g      *Grammar
	source string
	// hasA and hasG say the pattern uses \A or \G, so it compiles differently depending on
	// whether they may match.
	hasA, hasG bool
	// hasBackReferences says the pattern refers to groups; for an end or while pattern they
	// are groups of the begin pattern.
	hasBackReferences bool

	once [4]sync.Once
	re   [4]*regexp2.Regexp
	slot [4]int
}

var backReference = regexp.MustCompile(`\\(\d+)`)

// patternSlots numbers compiled patterns, across grammars, for Tokenizer's search cache.
var patternSlots atomic.Int64

func newPattern(g *Grammar, source string) *pattern {
	p := &pattern{g: g}
	// Lines end with "\n" when they are tokenized, so \z would only match after it.
	// vscode-textmate makes it match at the end of the text before it.
	var b strings.Builder
	for i := 0; i < len(source); i++ {
		if source[i] != '\\' || i+1 >= len(source) {
			b.WriteByte(source[i])
			continue
		}
		switch source[i+1] {
		case 'z':
			b.WriteString(`$(?!\n)(?<!\n)`)
		case 'A':
			p.hasA = true
			b.WriteString(source[i : i+2])
		case 'G':
			p.hasG = true
			b.WriteString(source[i : i+2])
		default:
			b.WriteString(source[i : i+2])
		}
		i++
	}
	p.source = b.String()
	p.hasBackReferences = backReference.MatchString(p.source)
	return p
}

// compiled returns the regular expression for a search where \A and \G may or may not match,
// with its cache slot, or nil when the pattern does not compile.
func (p *pattern) compiled(allowA, allowG bool) (*regexp2.Regexp, int) {
	variant := 0
	if p.hasA && !allowA {
		variant |= 1
	}
	if p.hasG && !allowG {
		variant |= 2
	}
	p.once[variant].Do(func() {
		re, err := compilePattern(p.source, variant&1 != 0, variant&2 != 0)
		if err != nil {
			p.g.patternFailed(err)
			return
		}
		p.re[variant] = re
		p.slot[variant] = int(patternSlots.Add(1))
	})
	return p.re[variant], p.slot[variant]
}

// resolvedPattern returns the rule's end or while pattern p with its back-references
// replaced by what the begin pattern captured, as resolveBackReferences computed.
func (r *rule) resolvedPattern(p *pattern, source string) *pattern {
	r.resolvedMu.Lock()
	defer r.resolvedMu.Unlock()
	if resolved, ok := r.resolved[source]; ok {
		return resolved
	}
	if r.resolved == nil || len(r.resolved) >= 256 {
		r.resolved = map[string]*pattern{}
	}
	resolved := newPattern(p.g, source)
	r.resolved[source] = resolved
	return resolved
}

// resolveBackReferences returns p's source with each \n replaced by the text group n of the
// begin match captured, escaped.
func resolveBackReferences(p *pattern, text []rune, caps []span) string {
	return backReference.ReplaceAllStringFunc(p.source, func(reference string) string {
		index, _ := strconv.Atoi(reference[1:])
		if index >= len(caps) {
			return ""
		}
		return escapeLiteral(string(text[caps[index].start:caps[index].end]))
	})
}

// scanner returns the patterns that start something inside r, compiling the list on first
// use.
func (r *rule) scanner(g *Grammar) []entry {
	r.scanOnce.Do(func() {
		var out []entry
		visiting := map[int]bool{}
		if r.kind == matchRule {
			g.collect(r, &out, visiting)
		} else {
			for _, id := range r.patterns {
				g.collect(g.rule(id), &out, visiting)
			}
		}
		r.entries = out
	})
	return r.entries
}

// collect appends the patterns that start r: its match or begin pattern, or the patterns of
// an include-only rule.
func (g *Grammar) collect(r *rule, out *[]entry, visiting map[int]bool) {
	switch r.kind {
	case matchRule:
		*out = append(*out, entry{rule: r.id, pat: r.match})
	case beginEndRule, beginWhileRule:
		*out = append(*out, entry{rule: r.id, pat: r.begin})
	case externalRule:
		if id := g.resolve(r); id > 0 {
			g.collect(g.rule(id), out, visiting)
		}
	default:
		if visiting[r.id] {
			return
		}
		visiting[r.id] = true
		for _, id := range r.patterns {
			g.collect(g.rule(id), out, visiting)
		}
		delete(visiting, r.id)
	}
}

// resolve compiles what the externalRule r includes, the first time it is asked, and returns
// the id of the rule the include names, or -1 when it names nothing.
func (g *Grammar) resolve(r *rule) int {
	g.compileMu.Lock()
	defer g.compileMu.Unlock()
	if r.target == 0 {
		r.target = g.compiler.include(r.include, &repo{base: r.base}, false)
		g.compiler.publish()
	}
	return r.target
}

// repo is the repository rules of one grammar resolve "#name" includes in: a nested
// repository in front of the one around it.
type repo struct {
	entries map[string]*RawRule
	parent  *repo
	// self and base are the rules $self and $base include.
	self, base *RawRule
}

func (r *repo) lookup(key string) *RawRule {
	for at := r; at != nil; at = at.parent {
		if rule, ok := at.entries[key]; ok {
			return rule
		}
	}
	return nil
}

// compiler builds one Grammar from raw grammars, as vscode-textmate's RuleFactory does. It
// compiles the rules a grammar reaches without including another grammar; an include of a
// grammar not compiled yet becomes an externalRule, which compiles that grammar when the
// tokenizer first collects it. vscode-textmate leaves out a rule all of whose patterns include
// what does not exist; an externalRule is kept as long as its grammar exists, even when the
// rule the include names after a "#" turns out not to.
type compiler struct {
	g      *Grammar
	source *grammarSource
	// rules are the rules compiled so far by id; Grammar.rules is what was last published.
	rules []*rule
	// ids are the compiled rules by the raw rule they came from.
	ids map[*RawRule]int
	// included are the repositories of the grammars included by scope.
	included map[string]*repo
	// deferred are the externalRules by what they include.
	deferred map[externalKey]int
	top      *repo
}

// externalKey is an include of another grammar and the rule $base names in it.
type externalKey struct {
	include string
	base    *RawRule
}

func compileGrammar(raw *RawGrammar, source *grammarSource) *Grammar {
	g := &Grammar{scopeName: raw.ScopeName, scopes: map[scopeKey]*ScopeStack{}}
	c := &compiler{
		g: g, source: source, rules: []*rule{nil}, ids: map[*RawRule]int{},
		included: map[string]*repo{}, deferred: map[externalKey]int{},
	}
	g.compiler = c
	c.top = c.grammarRepo(raw, nil)
	c.included[raw.ScopeName] = c.top
	g.root = c.ruleID(c.top.self, c.top)
	c.publish()
	rootName := c.rules[g.root].name.text
	if rootName == "" {
		rootName = "unknown"
	}
	g.rootStk = &ScopeStack{scope: rootName, depth: 1}
	g.initial = &StateStack{rule: g.root, enter: -1, anchor: -1, names: g.rootStk, content: g.rootStk, depth: 1}
	return g
}

// grammarRepo is the repository of raw with $self and $base, as initGrammar makes it; a nil
// base is the grammar itself.
func (c *compiler) grammarRepo(raw *RawGrammar, base *RawRule) *repo {
	self := &RawRule{Patterns: raw.Patterns, Name: raw.ScopeName}
	if base == nil {
		base = self
	}
	return &repo{entries: raw.Repository, self: self, base: base}
}

// publish makes the rules compiled so far visible to tokenizers. Rules are only ever appended
// after the published ones, so a reader of an earlier list never sees one change.
func (c *compiler) publish() {
	rules := c.rules
	c.g.rules.Store(&rules)
}

// external returns the repository of the grammar of scope, or nil when it is not registered.
func (c *compiler) external(scope string, from *repo) *repo {
	if r, ok := c.included[scope]; ok {
		return r
	}
	raw := c.source.raw(scope)
	if raw == nil {
		return nil
	}
	r := c.grammarRepo(raw, from.base)
	c.included[scope] = r
	return r
}

// ruleID compiles desc, resolving its includes in rp, and returns its id. A raw rule is
// compiled once, the first time it is reached.
func (c *compiler) ruleID(desc *RawRule, rp *repo) int {
	if id, ok := c.ids[desc]; ok {
		return id
	}
	id := len(c.rules)
	c.rules = append(c.rules, nil)
	c.ids[desc] = id
	r := &rule{id: id, name: newName(desc.Name), contentName: newName(desc.ContentName)}
	switch {
	case desc.Match != "":
		r.kind = matchRule
		r.match = newPattern(c.g, desc.Match)
		r.captures = c.captures(desc.Captures, rp)
	case desc.Begin == "":
		r.kind = includeOnlyRule
		if desc.Repository != nil {
			rp = &repo{entries: desc.Repository, parent: rp, self: rp.self, base: rp.base}
		}
		patterns := desc.Patterns
		if patterns == nil && desc.Include != "" {
			patterns = []*RawRule{{Include: desc.Include}}
		}
		r.patterns, r.missingPatterns = c.patterns(patterns, rp)
	case desc.While != "":
		r.kind = beginWhileRule
		r.begin = newPattern(c.g, desc.Begin)
		r.while = newPattern(c.g, desc.While)
		r.beginCaptures = c.captures(firstCaptures(desc.BeginCaptures, desc.Captures), rp)
		r.whileCaptures = c.captures(firstCaptures(desc.WhileCaptures, desc.Captures), rp)
		r.patterns, r.missingPatterns = c.patterns(desc.Patterns, rp)
	default:
		r.kind = beginEndRule
		r.begin = newPattern(c.g, desc.Begin)
		r.end = newPattern(c.g, desc.End)
		r.applyEndPatternLast = bool(desc.ApplyEndPatternLast)
		r.beginCaptures = c.captures(firstCaptures(desc.BeginCaptures, desc.Captures), rp)
		r.endCaptures = c.captures(firstCaptures(desc.EndCaptures, desc.Captures), rp)
		r.patterns, r.missingPatterns = c.patterns(desc.Patterns, rp)
	}
	c.rules[id] = r
	return id
}

func firstCaptures(captures, fallback RawCaptures) RawCaptures {
	if captures != nil {
		return captures
	}
	return fallback
}

// captures compiles the capture rules of one pattern, indexed by group.
func (c *compiler) captures(raw RawCaptures, rp *repo) []*captureRule {
	if len(raw) == 0 {
		return nil
	}
	numbers := make([]int, 0, len(raw))
	for number := range raw {
		numbers = append(numbers, number)
	}
	sort.Ints(numbers)
	out := make([]*captureRule, numbers[len(numbers)-1]+1)
	for _, number := range numbers {
		desc := raw[number]
		capture := &captureRule{name: newName(desc.Name), contentName: newName(desc.ContentName)}
		if desc.Patterns != nil {
			capture.retokenize = c.ruleID(desc, rp)
		}
		out[number] = capture
	}
	return out
}

// patterns compiles a rule's patterns, resolving includes, and says whether any of them
// referred to what does not exist.
func (c *compiler) patterns(list []*RawRule, rp *repo) ([]int, bool) {
	ids := make([]int, 0, len(list))
	for _, desc := range list {
		id := -1
		if desc.Include == "" {
			id = c.ruleID(desc, rp)
		} else {
			id = c.include(desc.Include, rp, true)
		}
		if id < 0 {
			continue
		}
		// A rule all of whose patterns are missing would match nothing; vscode-textmate
		// drops it. A rule still being compiled is part of a cycle and is kept.
		if r := c.rules[id]; r != nil && r.kind != matchRule && r.kind != externalRule && r.missingPatterns && len(r.patterns) == 0 {
			continue
		}
		ids = append(ids, id)
	}
	return ids, len(ids) != len(list)
}

// include resolves one include: $self, $base, #name, a scope, or scope#name. It returns -1
// when the include refers to nothing. When deferExternal is set, an include of a grammar that exists
// but is not compiled yet returns an externalRule instead of compiling that grammar.
func (c *compiler) include(include string, rp *repo, deferExternal bool) int {
	switch include {
	case "$self":
		return c.ruleID(rp.self, rp)
	case "$base":
		return c.ruleID(rp.base, rp)
	}
	scope, ruleName, local := strings.Cut(include, "#")
	if local && scope == "" {
		if desc := rp.lookup(ruleName); desc != nil {
			return c.ruleID(desc, rp)
		}
		return -1
	}
	if _, compiled := c.included[scope]; !compiled && deferExternal {
		if !c.source.has(scope) {
			return -1
		}
		return c.externalRule(include, rp.base)
	}
	external := c.external(scope, rp)
	if external == nil {
		return -1
	}
	if !local {
		return c.ruleID(external.self, external)
	}
	if desc := external.lookup(ruleName); desc != nil {
		return c.ruleID(desc, external)
	}
	return -1
}

// externalRule returns the externalRule of include with base, making it on first use.
func (c *compiler) externalRule(include string, base *RawRule) int {
	key := externalKey{include, base}
	if id, ok := c.deferred[key]; ok {
		return id
	}
	id := len(c.rules)
	c.rules = append(c.rules, &rule{id: id, kind: externalRule, include: include, base: base})
	c.deferred[key] = id
	return id
}
