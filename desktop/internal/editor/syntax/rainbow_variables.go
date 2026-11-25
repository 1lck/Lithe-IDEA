package syntax

import (
	"bytes"
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

type variableCandidates struct {
	ranges        []Variable
	afterAccessor bool
	language      string
	javaNames     map[string]struct{}
	javaPattern   javaPatternVariable
}

func (v *variableCandidates) appendLine(line []byte, tokens []textmate.Token, lineStart int) bool {
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
		member := v.afterAccessor
		v.afterAccessor = scopeMatches(scope, "punctuation.accessor") ||
			scopeMatches(scope, "punctuation.other.period") || scopeMatches(scope, "punctuation.separator.period") ||
			scopeMatches(scope, "keyword.operator.access.dot")
		patternBinding := v.language == "java" && v.javaPattern.binding(scope, word)
		wildcard := len(word) == 1 && word[0] == '_' && (v.language == "go" || v.language == "rust")
		if member || wildcard || len(word) > rainbowVariableMaxNameBytes {
			continue
		}
		marked := patternBinding || rainbowVariableScope(scope)
		// References can be plain runs inside calls, try bodies and other scopes nested
		// in the method. Only recognize bare identifiers already seen as a variable.
		plainJava := v.language == "java" && javaPlainMethodToken(token.Scopes)
		identifier := word
		if v.language == "rust" {
			// The grammar includes the raw identifier prefix in the variable token.
			// Validate its name, but retain the exact spelling and source range.
			identifier = bytes.TrimPrefix(identifier, []byte("r#"))
		}
		if !(marked || plainJava) || !rainbowVariableName(identifier) {
			continue
		}
		_, declared := v.javaNames[string(word)]
		if !marked && !declared {
			continue
		}
		if v.language == "java" && !declared && scopeMatches(scope, "variable.other.object") {
			// TextMate uses the same object scope for a receiver and a static type
			// qualifier. Leave an unknown conventionally named type in its theme style.
			first, _ := utf8.DecodeRune(word)
			if unicode.IsUpper(first) {
				continue
			}
		}
		if len(v.ranges) == rainbowVariableMaxCount {
			v.ranges, v.javaNames = nil, nil
			return false
		}
		name := string(word)
		if v.language == "java" && (patternBinding || scopeMatches(scope, "variable.other.definition") || scopeMatches(scope, "variable.parameter")) {
			if v.javaNames == nil {
				v.javaNames = make(map[string]struct{})
			}
			v.javaNames[name] = struct{}{}
		}
		start := uint32(lineStart + token.Start + len(raw) - len(bytes.TrimLeftFunc(raw, unicode.IsSpace)))
		v.ranges = append(v.ranges, Variable{Start: start, End: start + uint32(len(word)), Name: name})
	}
	return true
}

func javaPlainMethodToken(scopes *textmate.ScopeStack) bool {
	if !scopeMatches(scopes.Scope(), "meta") {
		return false
	}
	for at := scopes; at != nil; at = at.Parent() {
		if scopeMatches(at.Scope(), "meta.method.body") {
			return true
		}
	}
	return false
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
