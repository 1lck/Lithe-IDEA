package syntax

import "bytes"

// javaPatternVariable recognizes a plain binding after a type marked by the Java grammar.
// The bundled grammar scopes instanceof, the type and generic delimiters, but leaves the
// binding in an unclassified token such as map in instanceof Map<?, ?> map.
type javaPatternVariable struct {
	active, hasType bool
	typeArguments   int
}

func (p *javaPatternVariable) binding(scope string, word []byte) bool {
	if scopeMatches(scope, "keyword.operator.instanceof") {
		*p = javaPatternVariable{active: true}
		return false
	}
	if !p.active {
		return false
	}
	if p.hasType && bytes.Equal(word, []byte("<")) {
		p.typeArguments++
		return false
	}
	if p.typeArguments > 0 {
		if len(word) <= 3 && bytes.Count(word, []byte(">")) == len(word) {
			p.typeArguments -= len(word)
			if p.typeArguments < 0 {
				*p = javaPatternVariable{}
			}
		} else if scopeMatches(scope, "punctuation.bracket") || scopeMatches(scope, "punctuation.terminator") ||
			scopeMatches(scope, "keyword.operator.assignment") {
			*p = javaPatternVariable{}
		}
		return false
	}
	if scopeMatches(scope, "storage.type") || scopeMatches(scope, "entity.name.type") {
		p.hasType = true
		return false
	}
	matched := p.hasType && scopeMatches(scope, "meta") && rainbowVariableName(word)
	*p = javaPatternVariable{}
	return matched
}
