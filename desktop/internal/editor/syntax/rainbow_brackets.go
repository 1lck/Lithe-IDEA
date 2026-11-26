package syntax

import (
	"bytes"
	"context"

	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/rope"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/textmate"
)

const (
	// RainbowBracketMaxBytes bounds the document a background scan may tokenize.
	RainbowBracketMaxBytes = 1 << 20
	// rainbowBracketMaxCount matches the input limit of Core's editor.rainbowBrackets.
	rainbowBracketMaxCount = 10_000
)

// Bracket identifies one source delimiter by its absolute UTF-8 byte offset.
type Bracket struct {
	Offset  uint32 `json:"offset"`
	Bracket string `json:"bracket"`
}

// RainbowBrackets returns the source delimiters of a snapshot for background pairing by Core.
func RainbowBrackets(ctx context.Context, text rope.Rope, language *Syntax) []Bracket {
	brackets, _ := RainbowCandidates(ctx, text, language, true, false)
	return brackets
}

// RainbowCandidates is the synchronous snapshot helper used by isolated consumers and tests.
// Live editors consume Highlighter.Candidates and reuse their incremental tokenization.
func RainbowCandidates(ctx context.Context, text rope.Rope, language *Syntax, wantBrackets, wantVariables bool) ([]Bracket, []Variable) {
	if language == nil || text.Len() > RainbowBracketMaxBytes || !wantBrackets && !wantVariables {
		return nil, nil
	}
	h := newHighlighter(language, text, HighlighterOptions{LineLimit: -1, CollectCandidates: true}, false)
	defer h.Close()
	for h.step() {
		if ctx.Err() != nil {
			return nil, nil
		}
	}
	result, err := h.Candidates(ctx, text)
	if err != nil {
		return nil, nil
	}
	if !wantBrackets {
		result.Brackets = nil
	}
	if !wantVariables {
		result.Variables = nil
	}
	return result.Brackets, result.Variables
}

func appendRainbowBrackets(brackets []Bracket, line []byte, tokens []textmate.Token, start, limit int) ([]Bracket, bool) {
	token := 0
	for from := 0; from < len(line); {
		next := bytes.IndexAny(line[from:], "()[]{}")
		if next < 0 {
			break
		}
		at := from + next
		from = at + 1
		for token+1 < len(tokens) && tokens[token+1].Start <= at {
			token++
		}
		if len(tokens) == 0 || !codeTokenScope(tokens[token].Scopes) {
			continue
		}
		if len(brackets) == limit {
			return brackets, false
		}
		brackets = append(brackets, Bracket{Offset: uint32(start + at), Bracket: string(line[at:from])})
	}
	return brackets, true
}

// codeTokenScope excludes candidate ranges whose TextMate token belongs to a literal or comment.
// A template substitution may contain real code and inner literals. Its delimiters stay in
// the template style, while its code uses the same bracket rules as the surrounding source.
func codeTokenScope(scopes *textmate.ScopeStack) bool {
	for at := scopes; at != nil; at = at.Parent() {
		scope := at.Scope()
		switch {
		case scopeMatches(scope, "comment"), scopeMatches(scope, "string"),
			scopeMatches(scope, "constant.character"), scopeMatches(scope, "punctuation.definition.template-expression"):
			return false
		case scopeMatches(scope, "meta.template.expression"), scopeMatches(scope, "meta.embedded.expression"):
			return true
		}
	}
	return true
}
