package syntax

import "bytes"

// patternBinding follows a grammar-declared keyword/type/binding sequence. The state
// crosses line and segment boundaries and participates in tokenizer convergence.
type patternBinding struct {
	active, hasType bool
	arguments       int
}

func (p *patternBinding) consume(scope string, word []byte, rules *CandidateRules) bool {
	if rules.BindingKeyword == "" {
		return false
	}
	if scopeMatches(scope, rules.BindingKeyword) {
		*p = patternBinding{active: true}
		return false
	}
	if !p.active {
		return false
	}
	if p.hasType && bytes.Equal(word, []byte("<")) {
		p.arguments++
		return false
	}
	if p.arguments > 0 {
		if len(word) <= 3 && bytes.Count(word, []byte(">")) == len(word) {
			p.arguments -= len(word)
			if p.arguments < 0 {
				*p = patternBinding{}
			}
		} else if scopeMatches(scope, "punctuation.bracket") || scopeMatches(scope, "punctuation.terminator") || scopeMatches(scope, "keyword.operator.assignment") {
			*p = patternBinding{}
		}
		return false
	}
	if matchesAnyScope(scope, rules.TypeScopes) {
		p.hasType = true
		return false
	}
	matched := p.hasType && scopeMatches(scope, "meta") && rainbowVariableName(word)
	*p = patternBinding{}
	return matched
}
