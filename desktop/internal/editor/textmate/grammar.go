package textmate

import (
	"bytes"
	"encoding/json"
	"fmt"
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
type RawGrammar struct {
	ScopeName  string              `json:"scopeName"`
	Name       string              `json:"name"`
	FileTypes  []string            `json:"fileTypes"`
	Patterns   []*RawRule          `json:"patterns"`
	Repository map[string]*RawRule `json:"repository"`
}

// RawRule is one rule of a RawGrammar.
type RawRule struct {
	Include             string              `json:"include"`
	Name                string              `json:"name"`
	ContentName         string              `json:"contentName"`
	Match               string              `json:"match"`
	Begin               string              `json:"begin"`
	End                 string              `json:"end"`
	While               string              `json:"while"`
	Captures            RawCaptures         `json:"captures"`
	BeginCaptures       RawCaptures         `json:"beginCaptures"`
	EndCaptures         RawCaptures         `json:"endCaptures"`
	WhileCaptures       RawCaptures         `json:"whileCaptures"`
	Patterns            []*RawRule          `json:"patterns"`
	Repository          map[string]*RawRule `json:"repository"`
	ApplyEndPatternLast flag                `json:"applyEndPatternLast"`
}

// RawCaptures are the rules of a rule's capture groups by group number. Grammars write them
// as an object keyed by the number; an array is read by position.
type RawCaptures map[int]*RawRule

// UnmarshalJSON reads captures written as an object or as an array.
func (c *RawCaptures) UnmarshalJSON(data []byte) error {
	data = bytes.TrimSpace(data)
	captures := RawCaptures{}
	if len(data) > 0 && data[0] == '[' {
		var list []*RawRule
		if err := json.Unmarshal(data, &list); err != nil {
			return err
		}
		for i, rule := range list {
			if rule != nil {
				captures[i] = rule
			}
		}
		*c = captures
		return nil
	}
	var object map[string]json.RawMessage
	if err := json.Unmarshal(data, &object); err != nil {
		return err
	}
	for key, value := range object {
		number, err := strconv.Atoi(key)
		if err != nil || number < 0 {
			// vscode-textmate's own location field and the like.
			continue
		}
		var rule RawRule
		if err := json.Unmarshal(value, &rule); err != nil {
			return err
		}
		captures[number] = &rule
	}
	*c = captures
	return nil
}

// flag is a boolean a grammar may write as true, 1 or "1".
type flag bool

// UnmarshalJSON reads a boolean, a number or a string as a flag.
func (f *flag) UnmarshalJSON(data []byte) error {
	switch strings.Trim(string(bytes.TrimSpace(data)), `"`) {
	case "", "0", "false", "null":
		*f = false
	default:
		*f = true
	}
	return nil
}

// ParseGrammar reads a TextMate grammar in JSON.
func ParseGrammar(data []byte) (*RawGrammar, error) {
	var grammar RawGrammar
	if err := json.Unmarshal(data, &grammar); err != nil {
		return nil, fmt.Errorf("textmate grammar: %w", err)
	}
	if grammar.ScopeName == "" {
		return nil, fmt.Errorf("textmate grammar: no scopeName")
	}
	return &grammar, nil
}

// Registry holds the grammars one editor knows, so that a grammar can include another by its
// scope name. It is safe for concurrent use.
type Registry struct {
	mu       sync.Mutex
	raw      map[string]*RawGrammar
	compiled map[string]*Grammar
}

// NewRegistry returns an empty registry.
func NewRegistry() *Registry {
	return &Registry{raw: map[string]*RawGrammar{}, compiled: map[string]*Grammar{}}
}

// Add registers grammar under its scope name, in place of a grammar registered there before.
// Grammars compiled before keep working with what they included; Grammar compiles them anew.
func (r *Registry) Add(grammar *RawGrammar) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.raw[grammar.ScopeName] = grammar
	clear(r.compiled)
}

// Remove unregisters the grammar of scope.
func (r *Registry) Remove(scope string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	delete(r.raw, scope)
	clear(r.compiled)
}

// Grammar returns the compiled grammar of scope, compiling it and what it includes on first
// use, or false when no grammar has that scope.
func (r *Registry) Grammar(scope string) (*Grammar, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if g, ok := r.compiled[scope]; ok {
		return g, true
	}
	raw, ok := r.raw[scope]
	if !ok {
		return nil, false
	}
	g := compileGrammar(raw, func(scope string) *RawGrammar { return r.raw[scope] })
	r.compiled[scope] = g
	return g, true
}

// Grammar is a compiled TextMate grammar. Its rules are fixed once compiled; patterns are
// compiled to regular expressions on first use. It is safe for concurrent use.
type Grammar struct {
	scopeName string
	// rules are the grammar's rules by id; rules[0] is unused.
	rules []*rule
	root  int

	scopesMu sync.Mutex
	scopes   map[scopeKey]*ScopeStack
	rootStk  *ScopeStack
	initial  *StateStack

	errorsMu sync.Mutex
	errors   []error
}

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
				g.collect(g.rules[id], &out, visiting)
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
	default:
		if visiting[r.id] {
			return
		}
		visiting[r.id] = true
		for _, id := range r.patterns {
			g.collect(g.rules[id], out, visiting)
		}
		delete(visiting, r.id)
	}
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

// compiler builds one Grammar from raw grammars, as vscode-textmate's RuleFactory does.
type compiler struct {
	g      *Grammar
	lookup func(scope string) *RawGrammar
	// ids are the compiled rules by the raw rule they came from.
	ids map[*RawRule]int
	// included are the repositories of the grammars included by scope.
	included map[string]*repo
	top      *repo
}

func compileGrammar(raw *RawGrammar, lookup func(string) *RawGrammar) *Grammar {
	g := &Grammar{scopeName: raw.ScopeName, rules: []*rule{nil}, scopes: map[scopeKey]*ScopeStack{}}
	c := &compiler{g: g, lookup: lookup, ids: map[*RawRule]int{}, included: map[string]*repo{}}
	c.top = c.grammarRepo(raw, nil)
	c.included[raw.ScopeName] = c.top
	g.root = c.ruleID(c.top.self, c.top)
	rootName := g.rules[g.root].name.text
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

// external returns the repository of the grammar of scope, or nil when it is not registered.
func (c *compiler) external(scope string, from *repo) *repo {
	if r, ok := c.included[scope]; ok {
		return r
	}
	raw := c.lookup(scope)
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
	id := len(c.g.rules)
	c.g.rules = append(c.g.rules, nil)
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
	c.g.rules[id] = r
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
			id = c.include(desc.Include, rp)
		}
		if id < 0 {
			continue
		}
		// A rule all of whose patterns are missing would match nothing; vscode-textmate
		// drops it. A rule still being compiled is part of a cycle and is kept.
		if r := c.g.rules[id]; r != nil && r.kind != matchRule && r.missingPatterns && len(r.patterns) == 0 {
			continue
		}
		ids = append(ids, id)
	}
	return ids, len(ids) != len(list)
}

// include resolves one include: $self, $base, #name, a scope, or scope#name. It returns -1
// when the include refers to nothing.
func (c *compiler) include(include string, rp *repo) int {
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
