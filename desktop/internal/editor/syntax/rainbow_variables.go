package syntax

import (
	"bytes"
	"slices"
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/textmate"
)

const (
	// These match the Core command's limits for variable candidates.
	rainbowVariableMaxCount     = 10_000
	rainbowVariableMaxNameBytes = 256
)

// Variable identifies one variable candidate's exact spelling and absolute UTF-8 byte range.
type Variable struct {
	Start, End uint32
	Name       string
}

// CandidateRules is grammar metadata, independent of the language's ID. Empty rules use
// only generic variable scopes; custom grammars inherit the bundled metadata they extend.
type CandidateRules struct {
	ExcludedNames, IdentifierPrefixes                 []string
	DeclarationScopes, PlainContexts, QualifierScopes []string
	BindingKeyword                                    string
	TypeScopes                                        []string
}

type candidateLexState struct {
	afterAccessor bool
	binding       patternBinding
}

type variableCandidates struct {
	limit  int
	ranges []Variable
	roles  []uint8
	rules  *CandidateRules
	state  candidateLexState
}

const (
	candidateDeclaration uint8 = 1 << iota
	candidateNeedsDeclaration
	candidateQualifier
)

func matchesAnyScope(scope string, patterns []string) bool {
	for _, pattern := range patterns {
		if scopeMatches(scope, pattern) {
			return true
		}
	}
	return false
}

func (v *variableCandidates) appendLine(line []byte, tokens []textmate.Token, lineStart int) bool {
	complete := true
	rules := v.rules
	if rules == nil {
		rules = &CandidateRules{}
	}
	for i, token := range tokens {
		end := len(line)
		if i+1 < len(tokens) {
			end = tokens[i+1].Start
		}
		raw := line[token.Start:end]
		word := bytes.TrimSpace(raw)
		if len(word) == 0 || !codeTokenScope(token.Scopes) {
			continue
		}
		scope := token.Scopes.Scope()
		member := v.state.afterAccessor
		v.state.afterAccessor = scopeMatches(scope, "punctuation.accessor") ||
			scopeMatches(scope, "punctuation.other.period") || scopeMatches(scope, "punctuation.separator.period") ||
			scopeMatches(scope, "keyword.operator.access.dot")
		binding := v.state.binding.consume(scope, word, rules)
		if member || slices.Contains(rules.ExcludedNames, string(word)) || len(word) > rainbowVariableMaxNameBytes {
			continue
		}
		marked := binding || rainbowVariableScope(scope)
		plain := false
		if scopeMatches(scope, "meta") {
			for at := token.Scopes; at != nil; at = at.Parent() {
				if matchesAnyScope(at.Scope(), rules.PlainContexts) {
					plain = true
					break
				}
			}
		}
		identifier := word
		for _, prefix := range rules.IdentifierPrefixes {
			if bytes.HasPrefix(identifier, []byte(prefix)) {
				identifier = identifier[len(prefix):]
				break
			}
		}
		if !(marked || plain) || !rainbowVariableName(identifier) {
			continue
		}
		if len(v.ranges) == v.limit {
			complete = false
			continue
		}
		role := uint8(0)
		if binding || matchesAnyScope(scope, rules.DeclarationScopes) {
			role |= candidateDeclaration
		}
		if !marked {
			role |= candidateNeedsDeclaration
		}
		if matchesAnyScope(scope, rules.QualifierScopes) {
			first, _ := utf8.DecodeRune(word)
			if unicode.IsUpper(first) {
				role |= candidateQualifier
			}
		}
		start := uint32(lineStart + token.Start + len(raw) - len(bytes.TrimLeftFunc(raw, unicode.IsSpace)))
		v.ranges = append(v.ranges, Variable{Start: start, End: start + uint32(len(word)), Name: string(word)})
		v.roles = append(v.roles, role)
	}
	return complete
}

func rainbowVariableScope(scope string) bool {
	if !scopeMatches(scope, "variable") {
		return false
	}
	// The grammar uses nested variable scopes for properties, labels and language built-ins.
	// Filter by whole segments so forms such as variable.other.constant.object.property match.
	for part := range strings.SplitSeq(scope, ".") {
		switch part {
		case "property", "enummember", "import", "label", "language", "type", "metavariable", "regexp":
			return false
		}
	}
	return true
}

func rainbowVariableName(word []byte) bool {
	for offset, r := range string(word) {
		if !(r == '_' || r == '$' || unicode.IsLetter(r) || offset > 0 && (unicode.IsDigit(r) || unicode.IsMark(r))) {
			return false
		}
	}
	return len(word) > 0
}
