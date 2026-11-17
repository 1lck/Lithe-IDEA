package textmate

import (
	"bytes"
	"encoding/json"
	"regexp"
	"sort"
	"strconv"
)

// RawInjection is one entry of a grammar's injections: a scope selector and the rule whose
// patterns are tried, alongside the current rule's, wherever the selector matches.
type RawInjection struct {
	Selector string
	Rule     *RawRule
}

// injection is one selector of a compiled grammar's injections. A selector key with several
// comma-separated parts, such as "L:a, b", is one injection for each part, all with the rule
// of that key, as vscode-textmate's collectInjections makes them.
type injection struct {
	selector *selector
	// priority is -1 for a part written "L:", 1 for "R:" and 0 otherwise. Injections are kept
	// sorted by it, and an "L:" injection wins over the current rule's match at the same start.
	priority int
	rule     int
}

// collectInjections compiles the injections of the grammar being compiled, as
// vscode-textmate's Grammar._collectInjections does for its root grammar. The injections of
// a grammar it includes never apply, and no grammar is injected into another through an
// injectionSelector, so only the root's own are collected.
func (c *compiler) collectInjections(raw []RawInjection) []injection {
	var out []injection
	for _, raw := range raw {
		parts := parseSelector(raw.Selector)
		if len(parts) == 0 {
			continue
		}
		id := c.ruleID(raw.Rule, c.top)
		for _, part := range parts {
			out = append(out, injection{selector: part.selector, priority: part.priority, rule: id})
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].priority < out[j].priority })
	return out
}

// selectorKind is what one node of a parsed scope selector tests.
type selectorKind uint8

const (
	// selectorPath matches scopes that contain its names in order, each the scope itself or a
	// prefix of it that ends before a dot.
	selectorPath selectorKind = iota
	// selectorNot matches what its operand does not; with no operand it matches nothing.
	selectorNot
	// selectorAll matches what every operand matches, everything when there is none.
	selectorAll
	// selectorAny matches what one of its operands matches.
	selectorAny
)

// selector is a scope selector parsed as vscode-textmate's matcher.ts parses it.
type selector struct {
	kind     selectorKind
	names    []string
	operands []*selector
}

// selectorPart is one comma-separated part of a selector key with its priority.
type selectorPart struct {
	selector *selector
	priority int
}

// selectorToken is what matcher.ts's tokenizer takes from a selector: a priority prefix, a
// scope name, or punctuation. Everything else is skipped.
var selectorToken = regexp.MustCompile(`[LR]:|[\w.:][\w.:\-]*|[,|\-()]`)

// isSelectorName is matcher.ts's isIdentifier: a token with a word character, dot or colon,
// which a priority prefix also has.
func isSelectorName(token string) bool {
	return token != "" && token != "," && token != "|" && token != "-" && token != "(" && token != ")"
}

// selectorParser is matcher.ts's recursive descent over the tokens of one selector.
type selectorParser struct {
	tokens []string
	next   int
	// token is the current token, "" past the end.
	token string
}

func (p *selectorParser) advance() {
	p.token = ""
	if p.next < len(p.tokens) {
		p.token = p.tokens[p.next]
		p.next++
	}
}

// parseSelector is matcher.ts's createMatchers: the parts of a selector key with their
// priorities. A part that starts with a two-character token ending in a colon takes it as its
// priority; one other than "L:" or "R:" counts as no priority.
func parseSelector(key string) []selectorPart {
	p := &selectorParser{tokens: selectorToken.FindAllString(key, -1)}
	p.advance()
	var parts []selectorPart
	for p.token != "" {
		priority := 0
		if len(p.token) == 2 && p.token[1] == ':' {
			switch p.token[0] {
			case 'R':
				priority = 1
			case 'L':
				priority = -1
			}
			p.advance()
		}
		parts = append(parts, selectorPart{selector: p.conjunction(), priority: priority})
		if p.token != "," {
			break
		}
		p.advance()
	}
	return parts
}

// conjunction is operands that must all match.
func (p *selectorParser) conjunction() *selector {
	all := &selector{kind: selectorAll}
	for operand := p.operand(); operand != nil; operand = p.operand() {
		all.operands = append(all.operands, operand)
	}
	return all
}

// inner is the expression in parentheses: conjunctions separated by "|" or ",", one of which
// must match.
func (p *selectorParser) inner() *selector {
	either := &selector{kind: selectorAny}
	for {
		either.operands = append(either.operands, p.conjunction())
		if p.token != "|" && p.token != "," {
			return either
		}
		for p.token == "|" || p.token == "," {
			p.advance()
		}
	}
}

// operand is a negation, a parenthesized expression, or a run of names; nil when the current
// token starts none of them.
func (p *selectorParser) operand() *selector {
	switch {
	case p.token == "-":
		p.advance()
		return &selector{kind: selectorNot, operands: []*selector{p.operand()}}
	case p.token == "(":
		p.advance()
		inner := p.inner()
		if p.token == ")" {
			p.advance()
		}
		return inner
	case isSelectorName(p.token):
		path := &selector{kind: selectorPath}
		for isSelectorName(p.token) {
			path.names = append(path.names, p.token)
			p.advance()
		}
		return path
	}
	return nil
}

// matches says the selector matches scopes, the stack a position is in.
func (s *selector) matches(scopes *ScopeStack) bool {
	switch s.kind {
	case selectorPath:
		return pathMatches(s.names, scopes)
	case selectorNot:
		return s.operands[0] != nil && !s.operands[0].matches(scopes)
	case selectorAll:
		for _, operand := range s.operands {
			if !operand.matches(scopes) {
				return false
			}
		}
		return true
	default:
		for _, operand := range s.operands {
			if operand.matches(scopes) {
				return true
			}
		}
		return false
	}
}

// pathMatches is vscode-textmate's nameMatcher: the names match scopes that, outermost first,
// contain a scope matching each name in order. Matching each name to the innermost scope that
// can take it, from the last name back, finds such scopes exactly when matching from the first
// name forward does, and walks the stack without copying it.
func pathMatches(names []string, scopes *ScopeStack) bool {
	at := scopes
	for i := len(names) - 1; i >= 0; i-- {
		for at != nil && !scopeMatches(at.scope, names[i]) {
			at = at.parent
		}
		if at == nil {
			return false
		}
		at = at.parent
	}
	return true
}

// scopeMatches says name selects scope: it is the scope, or a prefix of it followed by a dot.
func scopeMatches(scope, name string) bool {
	if scope == "" {
		return false
	}
	if scope == name {
		return true
	}
	return len(scope) > len(name) && scope[len(name)] == '.' && scope[:len(name)] == name
}

// injectionKeys returns the keys of the injections object of the grammar in data in the order
// a JavaScript object has them, which is the order vscode-textmate collects injections in:
// keys that are array indices first, by value, then the others as the file first writes them.
// A repeated "injections" key takes its last object, as decoding does.
func injectionKeys(data []byte) []string {
	dec := json.NewDecoder(bytes.NewReader(data))
	if token, err := dec.Token(); err != nil || token != json.Delim('{') {
		return nil
	}
	var keys []string
	for dec.More() {
		token, err := dec.Token()
		if err != nil {
			return nil
		}
		var value json.RawMessage
		if err := dec.Decode(&value); err != nil {
			return nil
		}
		if token == "injections" {
			keys = objectKeys(value)
		}
	}
	return keys
}

// objectKeys returns the keys of the JSON object in data, each once, in JavaScript order.
func objectKeys(data []byte) []string {
	dec := json.NewDecoder(bytes.NewReader(data))
	if token, err := dec.Token(); err != nil || token != json.Delim('{') {
		return nil
	}
	var indices, names []string
	seen := map[string]bool{}
	for dec.More() {
		token, err := dec.Token()
		if err != nil {
			return nil
		}
		var skipped json.RawMessage
		if err := dec.Decode(&skipped); err != nil {
			return nil
		}
		key, _ := token.(string)
		if seen[key] {
			continue
		}
		seen[key] = true
		if _, ok := arrayIndex(key); ok {
			indices = append(indices, key)
		} else {
			names = append(names, key)
		}
	}
	sort.Slice(indices, func(i, j int) bool {
		a, _ := arrayIndex(indices[i])
		b, _ := arrayIndex(indices[j])
		return a < b
	})
	return append(indices, names...)
}

// arrayIndex reads key as a JavaScript array index: a canonical decimal integer below 2^32-1.
func arrayIndex(key string) (uint64, bool) {
	n, err := strconv.ParseUint(key, 10, 32)
	if err != nil || n == 1<<32-1 || strconv.FormatUint(n, 10) != key {
		return 0, false
	}
	return n, true
}
