package textmate

import (
	"strings"
	"sync/atomic"
	"time"
)

// ScopeStack is the scopes a token is in, outermost first, as a persistent list: each stack
// is its parent with one more scope. A grammar interns the stacks it makes, so most equal
// stacks are the same pointer and have the same ID.
type ScopeStack struct {
	parent *ScopeStack
	scope  string
	// id numbers the interned stacks of one grammar from 1; 0 is a stack not interned.
	id    uint32
	depth int
}

// Parent is the stack without its innermost scope, nil for the grammar's root scope.
func (s *ScopeStack) Parent() *ScopeStack { return s.parent }

// Scope is the innermost scope.
func (s *ScopeStack) Scope() string { return s.scope }

// Depth is the number of scopes.
func (s *ScopeStack) Depth() int { return s.depth }

// ID is a number for the stack, unique within its grammar, or 0 when the grammar did not
// intern it. Callers key per-stack caches by it.
func (s *ScopeStack) ID() uint32 { return s.id }

// Scopes are the scopes, outermost first.
func (s *ScopeStack) Scopes() []string {
	scopes := make([]string, s.depth)
	for at := s; at != nil; at = at.parent {
		scopes[at.depth-1] = at.scope
	}
	return scopes
}

// String is the scopes separated by spaces.
func (s *ScopeStack) String() string { return strings.Join(s.Scopes(), " ") }

// Equal says the two stacks have the same scopes.
func (s *ScopeStack) Equal(other *ScopeStack) bool {
	for a, b := s, other; ; a, b = a.parent, b.parent {
		if a == b {
			return true
		}
		if a == nil || b == nil || a.depth != b.depth || a.scope != b.scope {
			return false
		}
	}
}

type scopeKey struct {
	parent *ScopeStack
	scope  string
}

// maxInternedScopes bounds a grammar's interned stacks; stacks made past it are not interned.
const maxInternedScopes = 1 << 17

// ScopeCount is one more than the largest ID of a stack the grammar has interned so far.
func (g *Grammar) ScopeCount() uint32 {
	g.scopesMu.Lock()
	defer g.scopesMu.Unlock()
	return uint32(len(g.scopes)) + 2
}

// pushScopes returns base with the space-separated scopes of path added.
func (g *Grammar) pushScopes(base *ScopeStack, path string) *ScopeStack {
	if path == "" {
		return base
	}
	if !strings.Contains(path, " ") {
		return g.pushScope(base, path)
	}
	for _, scope := range strings.Fields(path) {
		base = g.pushScope(base, scope)
	}
	return base
}

func (g *Grammar) pushScope(base *ScopeStack, scope string) *ScopeStack {
	key := scopeKey{parent: base, scope: scope}
	g.scopesMu.Lock()
	defer g.scopesMu.Unlock()
	if s, ok := g.scopes[key]; ok {
		return s
	}
	s := &ScopeStack{parent: base, scope: scope, depth: base.depth + 1}
	if len(g.scopes) < maxInternedScopes {
		// The root stack has ID 1.
		s.id = uint32(len(g.scopes)) + 2
		g.scopes[key] = s
	}
	return s
}

// StateStack is the tokenizer's state at the end of a line: the rules open there, innermost
// first. It is persistent; tokenizing a line never changes the state it starts from.
type StateStack struct {
	parent *StateStack
	rule   int
	// endRule is the end or while pattern with the begin match's back-references resolved,
	// when hasEndRule is set.
	endRule    string
	hasEndRule bool
	// names are the scopes of the rule's begin match; content adds its contentName.
	names, content *ScopeStack
	// beginCapturedEOL says the rule's begin match ran to the end of its line.
	beginCapturedEOL bool
	// enter and anchor are where on the line the rule was entered and where its begin match
	// ended, valid only while stamp is the stamp of the line being tokenized.
	enter, anchor int
	stamp         uint64
	depth         int
}

// Depth is the number of open rules, the grammar's root included.
func (s *StateStack) Depth() int { return s.depth }

// Scopes are the scopes a line that starts in this state starts in.
func (s *StateStack) Scopes() *ScopeStack { return s.content }

// Equal says a line starting in either state is tokenized the same, which lets incremental
// tokenizing stop once a line ends in the state it ended in before.
func (s *StateStack) Equal(other *StateStack) bool {
	if s == other {
		return true
	}
	if s == nil || other == nil || s.beginCapturedEOL != other.beginCapturedEOL || !s.content.Equal(other.content) {
		return false
	}
	for a, b := s, other; ; a, b = a.parent, b.parent {
		if a == b {
			return true
		}
		if a == nil || b == nil || a.depth != b.depth || a.rule != b.rule ||
			a.hasEndRule != b.hasEndRule || a.endRule != b.endRule {
			return false
		}
	}
}

func (s *StateStack) enterAt(stamp uint64) int {
	if s.stamp == stamp {
		return s.enter
	}
	return -1
}

func (s *StateStack) anchorAt(stamp uint64) int {
	if s.stamp == stamp {
		return s.anchor
	}
	return -1
}

func (s *StateStack) push(rule, enter, anchor int, capturedEOL bool, names, content *ScopeStack, stamp uint64) *StateStack {
	return &StateStack{
		parent: s, rule: rule, names: names, content: content, beginCapturedEOL: capturedEOL,
		enter: enter, anchor: anchor, stamp: stamp, depth: s.depth + 1,
	}
}

func (s *StateStack) withContent(content *ScopeStack) *StateStack {
	if s.content == content {
		return s
	}
	copied := *s
	copied.content = content
	return &copied
}

func (s *StateStack) withEndRule(source string) *StateStack {
	copied := *s
	copied.endRule, copied.hasEndRule = source, true
	return &copied
}

// safePop is the parent, or s itself at the root.
func (s *StateStack) safePop() *StateStack {
	if s.parent != nil {
		return s.parent
	}
	return s
}

// hasSameRuleAs says a rule entered where other was is already open as other's rule.
func (s *StateStack) hasSameRuleAs(other *StateStack, stamp uint64) bool {
	for at := s; at != nil && at.enterAt(stamp) == other.enterAt(stamp); at = at.parent {
		if at.rule == other.rule {
			return true
		}
	}
	return false
}

// Initial is the state the first line of a document starts in.
func (g *Grammar) Initial() *StateStack { return g.initial }

// Token is one token of a line: where it starts, in bytes, and the scopes it is in. A token
// runs to the next token's start or the end of the line.
type Token struct {
	Start  int
	Scopes *ScopeStack
}

// stamps number lines and texts as they are tokenized, across tokenizers.
var stamps atomic.Uint64

// span is where a match or a capture group is, in runes.
type span struct{ start, end int }

// text is a line as it is searched: its runes with "\n" appended, or a prefix of them when
// a capture is tokenized again.
type text struct {
	runes []rune
	stamp uint64
}

// cached is the last search of one compiled pattern: the groups it found, as
// regexp2.FindRunesSpans reports them, or none when matched is false. The slice keeps its
// capacity from search to search.
type cached struct {
	stamp   uint64
	from    int
	matched bool
	spans   []int
}

// Tokenizer tokenizes lines with one grammar. It keeps the search results of the line it is
// on, so it is not safe for concurrent use; each goroutine needs its own.
type Tokenizer struct {
	g *Grammar
	// stamp is the stamp of the line being tokenized.
	stamp   uint64
	runes   []rune
	offsets []int
	cache   []cached
	tokens  []rawToken
	lastEnd int
	// groups holds the group spans of every match of the line; search returns slices of it,
	// which stay valid until the next line.
	groups []span
	// line is the text of the line, kept here so that it is not allocated per line.
	line text
}

// rawToken is a token with its start in runes.
type rawToken struct {
	start  int
	scopes *ScopeStack
}

// NewTokenizer returns a tokenizer for g.
func (g *Grammar) NewTokenizer() *Tokenizer { return &Tokenizer{g: g} }

// Grammar is the tokenizer's grammar.
func (t *Tokenizer) Grammar() *Grammar { return t.g }

// TokenizeLine tokenizes one line, given without its line break, that starts in state prev,
// and appends its tokens to dst. A nil prev is the start of the document. It returns the
// tokens and the state the line ends in. With a positive limit, tokenizing stops once it has
// taken that long; stopped is then set, the tokens cover the line only up to where it
// stopped, and the state is not one a following line may start in.
func (t *Tokenizer) TokenizeLine(dst []Token, line []byte, prev *StateStack, limit time.Duration) (tokens []Token, end *StateStack, stopped bool) {
	first := prev == nil
	if first {
		prev = t.g.initial
	}
	t.stamp = stamps.Add(1)
	t.runes, t.offsets = t.runes[:0], t.offsets[:0]
	for offset, r := range string(line) {
		t.runes = append(t.runes, r)
		t.offsets = append(t.offsets, offset)
	}
	t.runes = append(t.runes, '\n')
	t.offsets = append(t.offsets, len(line))
	t.tokens, t.lastEnd = t.tokens[:0], 0
	t.groups = t.groups[:0]

	var deadline time.Time
	if limit > 0 {
		deadline = time.Now().Add(limit)
	}
	t.line = text{runes: t.runes, stamp: t.stamp}
	end, stopped = t.tokenizeText(&t.line, first, 0, prev, true, deadline)

	length := len(t.runes)
	if n := len(t.tokens); n > 0 && t.tokens[n-1].start == length-1 {
		// The token of the "\n" alone.
		t.tokens = t.tokens[:n-1]
	}
	if len(t.tokens) == 0 {
		t.lastEnd = -1
		t.produce(end.content, length)
		t.tokens[len(t.tokens)-1].start = 0
	}
	for _, token := range t.tokens {
		dst = append(dst, Token{Start: t.offsets[token.start], Scopes: token.scopes})
	}
	return dst, end, stopped
}

// produce ends the current token at end, in scopes.
func (t *Tokenizer) produce(scopes *ScopeStack, end int) {
	if t.lastEnd >= end {
		return
	}
	start := max(t.lastEnd, 0)
	t.tokens = append(t.tokens, rawToken{start: start, scopes: scopes})
	t.lastEnd = end
}

// tokenizeText is vscode-textmate's _tokenizeString: it tokenizes s from pos in state stack.
func (t *Tokenizer) tokenizeText(s *text, first bool, pos int, stack *StateStack, checkWhile bool, deadline time.Time) (*StateStack, bool) {
	length := len(s.runes)
	anchor := -1
	if checkWhile {
		stack, pos, first, anchor = t.checkWhileConditions(s, first, pos, stack)
	}
	for {
		if !deadline.IsZero() && time.Now().After(deadline) {
			return stack, true
		}
		id, caps := t.matchRule(s, first, pos, stack, anchor)
		if caps == nil {
			t.produce(stack.content, length)
			return stack, false
		}
		advanced := caps[0].end > pos
		if id == endRuleID {
			// The end of the innermost rule: pop it.
			popped := t.g.rule(stack.rule)
			t.produce(stack.content, caps[0].start)
			stack = stack.withContent(stack.names)
			t.captures(s, first, stack, popped.endCaptures, caps)
			t.produce(stack.content, caps[0].end)
			poppedStack := stack
			stack = stack.parent
			anchor = poppedStack.anchorAt(t.stamp)
			if !advanced && poppedStack.enterAt(t.stamp) == pos {
				// The grammar pushed and popped a rule without advancing; vscode-textmate
				// assumes it meant to stay in it and gives up on the line.
				stack = poppedStack
				t.produce(stack.content, length)
				return stack, false
			}
		} else {
			r := t.g.rule(id)
			t.produce(stack.content, caps[0].start)
			before := stack
			names := t.g.pushScopes(stack.content, r.name.resolve(s.runes, caps))
			stack = stack.push(id, pos, anchor, caps[0].end == length, names, names, t.stamp)
			switch r.kind {
			case beginEndRule, beginWhileRule:
				captures, follow := r.beginCaptures, r.end
				if r.kind == beginWhileRule {
					follow = r.while
				}
				t.captures(s, first, stack, captures, caps)
				t.produce(stack.content, caps[0].end)
				anchor = caps[0].end
				stack = stack.withContent(t.g.pushScopes(names, r.contentName.resolve(s.runes, caps)))
				if follow.hasBackReferences {
					stack = stack.withEndRule(resolveBackReferences(follow, s.runes, caps))
				}
				if !advanced && before.hasSameRuleAs(stack, t.stamp) {
					// The grammar pushed the same rule again without advancing.
					stack = stack.parent
					t.produce(stack.content, length)
					return stack, false
				}
			default:
				t.captures(s, first, stack, r.captures, caps)
				t.produce(stack.content, caps[0].end)
				stack = stack.parent
				if !advanced {
					// The grammar neither advances nor pushes or pops.
					stack = stack.safePop()
					t.produce(stack.content, length)
					return stack, false
				}
			}
		}
		if caps[0].end > pos {
			pos = caps[0].end
			first = false
		}
	}
}

// checkWhileConditions matches, outermost first, the while patterns of the begin/while rules
// open at the start of a line, and pops the first whose pattern does not match with
// everything inside it.
func (t *Tokenizer) checkWhileConditions(s *text, first bool, pos int, stack *StateStack) (*StateStack, int, bool, int) {
	anchor := -1
	if stack.beginCapturedEOL {
		anchor = 0
	}
	var whiles []*StateStack
	for node := stack; node != nil; node = node.parent {
		if t.g.rule(node.rule).kind == beginWhileRule {
			whiles = append(whiles, node)
		}
	}
	for i := len(whiles) - 1; i >= 0; i-- {
		node := whiles[i]
		r := t.g.rule(node.rule)
		p := r.while
		if node.hasEndRule {
			p = r.resolvedPattern(r.while, node.endRule)
		}
		_, caps := t.search(s, pos, first, pos == anchor, nil, entry{rule: whileRuleID, pat: p}, false)
		if caps == nil {
			stack = node.parent
			break
		}
		t.produce(node.content, caps[0].start)
		t.captures(s, first, node, r.whileCaptures, caps)
		t.produce(node.content, caps[0].end)
		anchor = caps[0].end
		if caps[0].end > pos {
			pos = caps[0].end
			first = false
		}
	}
	return stack, pos, first, anchor
}

// matchRule finds the leftmost match in s from pos among the patterns of the innermost rule
// of stack, its end pattern included, and returns the rule it starts and its groups.
func (t *Tokenizer) matchRule(s *text, first bool, pos int, stack *StateStack, anchor int) (int, []span) {
	r := t.g.rule(stack.rule)
	entries := r.scanner(t.g)
	if r.kind != beginEndRule {
		return t.search(s, pos, first, pos == anchor, entries, entry{}, false)
	}
	end := r.end
	if stack.hasEndRule {
		end = r.resolvedPattern(r.end, stack.endRule)
	}
	return t.search(s, pos, first, pos == anchor, entries, entry{rule: endRuleID, pat: end}, r.applyEndPatternLast)
}

// search finds the leftmost match in s from pos among entries and end, if end has a pattern,
// which comes first unless endLast is set. Of matches that start at the same place the first
// in that order wins. It returns the winning entry's rule and the match's groups, or nil
// groups when nothing matches.
func (t *Tokenizer) search(s *text, pos int, allowA, allowG bool, entries []entry, end entry, endLast bool) (int, []span) {
	var best []int
	bestRule := 0
	try := func(e entry) bool {
		m := t.find(s, pos, e.pat, allowA, allowG)
		if m == nil {
			return false
		}
		if best == nil || m[0] < best[0] {
			best, bestRule = m, e.rule
		}
		return m[0] == pos
	}
	done := false
	if end.pat != nil && !endLast {
		done = try(end)
	}
	for i := 0; !done && i < len(entries); i++ {
		done = try(entries[i])
	}
	if !done && end.pat != nil && endLast {
		try(end)
	}
	if best == nil {
		return 0, nil
	}
	return bestRule, t.keep(best)
}

// find searches s from pos with one pattern, answering from the cache where an earlier
// search of the same text already did.
//
// It returns the match as regexp2.FindRunesSpans reports it, nil when there is none. The
// slice belongs to the cache and changes with the next search of the same pattern.
func (t *Tokenizer) find(s *text, pos int, p *pattern, allowA, allowG bool) []int {
	re, slot := p.compiled(allowA, allowG)
	if re == nil {
		return nil
	}
	for slot >= len(t.cache) {
		t.cache = append(t.cache, make([]cached, len(t.cache)+64)...)
	}
	c := &t.cache[slot]
	// A search from an earlier position of the same text still answers this one when it found
	// nothing or found something at or after pos. \G depends on where the search starts, so
	// patterns that may match it are searched again.
	if c.stamp == s.stamp && c.from <= pos && !(p.hasG && allowG) {
		if !c.matched {
			return nil
		}
		if c.spans[0] >= pos {
			return c.spans
		}
	}
	spans, matched, err := re.FindRunesSpans(c.spans, s.runes, pos)
	if err != nil {
		// A search that passed its backtrack limit matches nothing.
		matched = false
	}
	c.stamp, c.from, c.matched, c.spans = s.stamp, pos, matched, spans
	if !matched {
		return nil
	}
	return spans
}

// keep copies a match's groups out of the cache into t.groups, where they stay until the next
// line; a group that did not take part is empty.
func (t *Tokenizer) keep(spans []int) []span {
	start := len(t.groups)
	for i := 0; i+1 < len(spans); i += 2 {
		if spans[i] < 0 {
			t.groups = append(t.groups, span{})
			continue
		}
		t.groups = append(t.groups, span{start: spans[i], end: spans[i+1]})
	}
	return t.groups[start:len(t.groups):len(t.groups)]
}

// localScope is a capture's scopes, open until end.
type localScope struct {
	scopes *ScopeStack
	end    int
}

// captures produces the tokens of a match's capture groups, as vscode-textmate's
// handleCaptures: nested groups nest their scopes, and a group with patterns is tokenized
// again with them.
func (t *Tokenizer) captures(s *text, first bool, stack *StateStack, rules []*captureRule, caps []span) {
	if len(rules) == 0 {
		return
	}
	n := min(len(rules), len(caps))
	maxEnd := caps[0].end
	var local []localScope
	for i := 0; i < n; i++ {
		capture := rules[i]
		if capture == nil {
			continue
		}
		c := caps[i]
		if c.end == c.start {
			continue
		}
		if c.start > maxEnd {
			// A group past what the match consumed, as a lookahead captures.
			break
		}
		for len(local) > 0 && local[len(local)-1].end <= c.start {
			top := local[len(local)-1]
			t.produce(top.scopes, top.end)
			local = local[:len(local)-1]
		}
		if len(local) > 0 {
			t.produce(local[len(local)-1].scopes, c.start)
		} else {
			t.produce(stack.content, c.start)
		}
		if capture.retokenize != 0 {
			names := t.g.pushScopes(stack.content, capture.name.resolve(s.runes, caps))
			content := t.g.pushScopes(names, capture.contentName.resolve(s.runes, caps))
			nested := stack.push(capture.retokenize, c.start, -1, false, names, content, t.stamp)
			sub := &text{runes: s.runes[:c.end:c.end], stamp: stamps.Add(1)}
			t.tokenizeText(sub, first && c.start == 0, c.start, nested, false, time.Time{})
			continue
		}
		if scope := capture.name.resolve(s.runes, caps); scope != "" {
			base := stack.content
			if len(local) > 0 {
				base = local[len(local)-1].scopes
			}
			local = append(local, localScope{scopes: t.g.pushScopes(base, scope), end: c.end})
		}
	}
	for len(local) > 0 {
		top := local[len(local)-1]
		t.produce(top.scopes, top.end)
		local = local[:len(local)-1]
	}
}
