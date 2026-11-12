package syntax

import (
	"sync"
	"sync/atomic"

	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/textmate"
)

// Rule gives the tokens in a TextMate scope a token name.
type Rule struct {
	// Scope is a scope or a prefix of scopes that ends at a dot: "string" matches "string" and
	// "string.quoted.double.java", but not "stringify".
	Scope string `json:"scope"`
	// Token is the token name the matching tokens get, such as "keyword" or "type.yaml". A theme
	// styles it by its longest dotted prefix that has a style, so a language may add a suffix
	// to restyle its own tokens without changing other languages.
	Token string `json:"token"`
	// Enclosing rules are tried before the others and match any scope of a token, not only its
	// innermost one, so that, for example, the punctuation inside a documentation comment is
	// still colored as the comment.
	Enclosing bool `json:"enclosing,omitempty"`
}

// A token's name comes from the first rule that matches it, in this order: each enclosing rule
// in turn, against every scope the token is in; then the token's scopes from the innermost
// outward, each tried against the other rules in turn. A token no rule matches is named "".
//
// A token of a language embedded in another, such as CSS in an HTML style element or Go in a
// Markdown code block, is named by the rules of the embedded language, against the scopes from
// the one the language is embedded under inward. A language is embedded under the root scope of
// its grammar, as HTML embeds source.css, or under meta.embedded.block.<language ID>,
// meta.embedded.line.<language ID> or meta.embedded.expression.<language ID>, as Markdown embeds
// its code blocks. A language embedded in itself, as TypeScript embeds a template literal's
// substitutions, is named against the scopes from the embedding inward in the same way.

// DefaultRules are the rules of a language that sets none. They are the previous editor's
// classification of TextMate scopes, which themes and color schemes are written against.
var DefaultRules = []Rule{
	{Scope: "support.function", Token: "function", Enclosing: true},
	{Scope: "comment.block.documentation", Token: "comment.documentation", Enclosing: true},
	{Scope: "comment.block.javadoc", Token: "comment.documentation", Enclosing: true},
	{Scope: "comment.block", Token: "comment.block", Enclosing: true},
	{Scope: "comment", Token: "comment.line"},
	{Scope: "punctuation.definition.comment", Token: "comment.line"},
	{Scope: "constant.character.escape", Token: "string.escape"},
	{Scope: "storage.type.annotation", Token: "annotation"},
	{Scope: "string", Token: "string"},
	{Scope: "constant.numeric", Token: "number"},
	{Scope: "constant.language", Token: "keyword"},
	{Scope: "keyword", Token: "keyword"},
	{Scope: "storage", Token: "keyword"},
	{Scope: "entity.name.type", Token: "type.identifier"},
	{Scope: "entity.name.class", Token: "type.identifier"},
	{Scope: "entity.name.namespace", Token: "type.identifier"},
	{Scope: "support.class", Token: "type.identifier"},
	{Scope: "support.type", Token: "type.identifier"},
	{Scope: "entity.name.function", Token: "function"},
	{Scope: "variable", Token: "variable"},
	{Scope: "punctuation", Token: "delimiter"},
}

// WithDefaults returns rules followed by DefaultRules, for a language that only adds to or
// overrides part of the default classification.
func WithDefaults(rules ...Rule) []Rule {
	return append(append(make([]Rule, 0, len(rules)+len(DefaultRules)), rules...), DefaultRules...)
}

// scopeMatches says scope is prefix or starts with prefix followed by a dot.
func scopeMatches(scope, prefix string) bool {
	return len(scope) >= len(prefix) && scope[:len(prefix)] == prefix &&
		(len(scope) == len(prefix) || scope[len(prefix)] == '.')
}

// classifier names the tokens of one compiled grammar. It remembers the name of each scope
// stack the grammar interned, by the stack's ID, and is safe for concurrent use: the UI and a
// highlighter's worker classify with it at the same time.
type classifier struct {
	// id is the ID of the language whose rules these are.
	id               string
	enclosing, inner []namedRule
	// embedded returns the classifier of the language embedded under a scope, or nil when no
	// language is.
	embedded func(scope string) *classifier
	// memo holds, by scope stack ID, one more than the stack's Name, or 0 when not yet known.
	// Its elements are read and written atomically; growing it replaces the slice.
	memo   atomic.Pointer[[]uint32]
	growMu sync.Mutex
}

type namedRule struct {
	scope string
	name  Name
}

func newClassifier(id string, rules []Rule, embedded func(scope string) *classifier) *classifier {
	c := &classifier{id: id, embedded: embedded}
	for _, rule := range rules {
		named := namedRule{scope: rule.Scope, name: Intern(rule.Token)}
		if rule.Enclosing {
			c.enclosing = append(c.enclosing, named)
		} else {
			c.inner = append(c.inner, named)
		}
	}
	memo := make([]uint32, 0)
	c.memo.Store(&memo)
	return c
}

// name returns the Name of a token in scopes.
func (c *classifier) name(scopes *textmate.ScopeStack) Name {
	if scopes == nil {
		return 0
	}
	id := scopes.ID()
	if id != 0 {
		if memo := *c.memo.Load(); int(id) < len(memo) {
			if v := atomic.LoadUint32(&memo[id]); v != 0 {
				return Name(v - 1)
			}
		}
	}
	n := c.compute(scopes)
	if id != 0 {
		c.remember(id, n)
	}
	return n
}

func (c *classifier) compute(scopes *textmate.ScopeStack) Name {
	if c.embedded != nil {
		// The root scope is the language's own; the innermost embedding decides, even one of
		// the language itself, such as a template literal's substitution, so that the code in it
		// is not named by the string around it.
		for at := scopes; at != nil && at.Parent() != nil; at = at.Parent() {
			if inner := c.embedded(at.Scope()); inner != nil {
				return inner.match(scopes, at)
			}
		}
	}
	return c.match(scopes, nil)
}

// match names a token by the rules, against its scopes from the innermost out to last, or to
// the root when last is nil.
func (c *classifier) match(scopes, last *textmate.ScopeStack) Name {
	for _, rule := range c.enclosing {
		for at := scopes; at != nil; at = at.Parent() {
			if scopeMatches(at.Scope(), rule.scope) {
				return rule.name
			}
			if at == last {
				break
			}
		}
	}
	for at := scopes; at != nil; at = at.Parent() {
		scope := at.Scope()
		for _, rule := range c.inner {
			if scopeMatches(scope, rule.scope) {
				return rule.name
			}
		}
		if at == last {
			break
		}
	}
	return 0
}

func (c *classifier) remember(id uint32, n Name) {
	if memo := *c.memo.Load(); int(id) < len(memo) {
		atomic.StoreUint32(&memo[id], uint32(n)+1)
		return
	}
	c.growMu.Lock()
	defer c.growMu.Unlock()
	old := *c.memo.Load()
	if int(id) >= len(old) {
		grown := make([]uint32, max(2*len(old), int(id)+1, 256))
		for i := range old {
			grown[i] = atomic.LoadUint32(&old[i])
		}
		c.memo.Store(&grown)
		old = grown
	}
	atomic.StoreUint32(&old[id], uint32(n)+1)
}
