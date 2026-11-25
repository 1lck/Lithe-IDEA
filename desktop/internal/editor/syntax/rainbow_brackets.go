package syntax

import (
	"bytes"
	"context"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/rope"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/textmate"
)

const (
	// RainbowBracketMaxBytes bounds the document a background scan may tokenize.
	RainbowBracketMaxBytes = 1 << 20
	// rainbowBracketMaxCount matches the input limit of Core's editor.rainbowBrackets.
	rainbowBracketMaxCount = 10_000
	// Cold grammar compilation shares this background line budget. The viewport's tighter
	// limit may leave a line incomplete during first use, which this scan cannot accept.
	rainbowBracketLineLimit = 250 * time.Millisecond
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

// RainbowCandidates uses a single grammar pass for the requested bracket and variable ranges.
// It runs off the window thread. Incomplete tokenization discards both sets since the lexical
// state is unknown. Each set has its own range budget, so overflow in one leaves the other valid.
func RainbowCandidates(ctx context.Context, text rope.Rope, language *Syntax, wantBrackets, wantVariables bool) ([]Bracket, []Variable) {
	if language == nil || text.Len() == 0 || text.Len() > RainbowBracketMaxBytes || !wantBrackets && !wantVariables {
		return nil, nil
	}
	tokenizer := language.grammar.NewTokenizer()
	var state *textmate.StateStack
	var tokens []textmate.Token
	var lineBytes []byte
	var brackets []Bracket
	variables := variableCandidates{language: language.Language().ID}
	deadline, hasDeadline := ctx.Deadline()
	start := 0
	for line, lines := 0, text.LineCount(); line < lines; line++ {
		end := text.LineEnd(line)
		if ctx.Err() != nil || end-start > maxLineBytes {
			return nil, nil
		}
		lineLimit := rainbowBracketLineLimit
		if hasDeadline {
			lineLimit = min(lineLimit, time.Until(deadline))
			if lineLimit <= 0 {
				return nil, nil
			}
		}
		lineBytes = text.AppendRange(lineBytes[:0], start, end)
		var stopped bool
		tokens, state, stopped = tokenizer.TokenizeLine(tokens[:0], lineBytes, state, lineLimit)
		if stopped {
			return nil, nil
		}
		if wantBrackets {
			brackets, wantBrackets = appendRainbowBrackets(brackets, lineBytes, tokens, start)
		}
		if wantVariables {
			wantVariables = variables.appendLine(lineBytes, tokens, start)
		}
		if !wantBrackets && !wantVariables {
			return nil, nil
		}
		start = end + 1
	}
	// log-exempt: 用户取消：替换或关闭编辑器后丢弃该快照的候选范围。
	if ctx.Err() != nil {
		return nil, nil
	}
	return brackets, variables.ranges
}

func appendRainbowBrackets(brackets []Bracket, line []byte, tokens []textmate.Token, start int) ([]Bracket, bool) {
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
		if len(brackets) == rainbowBracketMaxCount {
			return nil, false
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
