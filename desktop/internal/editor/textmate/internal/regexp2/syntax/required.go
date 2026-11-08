package syntax

import (
	"slices"
	"unicode/utf8"
)

// This file is a Lithe addition to regexp2.
//
// A backtracking search tries the pattern at every position of the text unless the pattern
// starts with something the prefix analysis can skip to. TextMate grammars often start with
// a lookahead, \b or a lookbehind, so most of their searches walk the whole line, and many
// walk it once per start position. Most of those patterns still need some literal text, as
// (?=\w?[\w\s-]*\b(?:class|interface|enum)\s+) needs "class", "interface" or "enum"; on a
// line that holds none of them after the start of the search, no position can match.

// maxRequiredLiterals bounds the set a pattern is checked against; a larger alternation is
// cheaper to search than to filter.
const maxRequiredLiterals = 32

// maxRequiredLength bounds the literal a counted repetition such as a{1000} is turned into.
const maxRequiredLength = 64

// Required is a set of literals at least one of which occurs, in every match, inside the
// match or inside a lookahead the match makes. A search from a position after which none of
// them occurs finds nothing.
type Required struct {
	literals [][]rune
	// ascii holds the ASCII runes a literal starts with; other is set when a literal starts
	// with a rune outside ASCII.
	ascii [2]uint64
	other bool
}

// Literals is the set, for tests and dumps.
func (q *Required) Literals() []string {
	out := make([]string, len(q.literals))
	for i, literal := range q.literals {
		out[i] = string(literal)
	}
	return out
}

// In reports whether one of the literals occurs in text at or after from.
func (q *Required) In(text []rune, from int) bool {
	for i := from; i < len(text); i++ {
		r := text[i]
		if uint32(r) < utf8.RuneSelf {
			if q.ascii[r>>6]&(1<<(uint32(r)&63)) == 0 {
				continue
			}
		} else if !q.other {
			continue
		}
		for _, literal := range q.literals {
			if literal[0] == r && len(text)-i >= len(literal) && slices.Equal(text[i:i+len(literal)], literal) {
				return true
			}
		}
	}
	return false
}

// requiredOf is the Required of a tree, nil when the analysis finds no literal every match
// needs or the search runs right to left.
func requiredOf(tree *RegexTree) *Required {
	if tree.options&RightToLeft != 0 {
		return nil
	}
	literals := required(tree.root)
	if len(literals) == 0 {
		return nil
	}
	q := &Required{literals: literals}
	for _, literal := range literals {
		if r := literal[0]; uint32(r) < utf8.RuneSelf {
			q.ascii[r>>6] |= 1 << (uint32(r) & 63)
		} else {
			q.other = true
		}
	}
	return q
}

// required is a set of literals one of which every match of n contains, or nil when there is
// none to rely on. It is conservative: a node it does not understand requires nothing.
func required(n *regexNode) [][]rune {
	if n.options&(IgnoreCase|RightToLeft) != 0 {
		// Case-folded text can differ from the literal, and a lookbehind reads text before
		// the search start.
		return nil
	}
	switch n.t {
	case ntOne:
		return [][]rune{{n.ch}}
	case ntMulti:
		if len(n.str) == 0 {
			return nil
		}
		return [][]rune{n.str}
	case ntOnerep, ntOneloop, ntOnelazy:
		if n.m < 1 {
			return nil
		}
		count := min(n.m, maxRequiredLength)
		literal := make([]rune, count)
		for i := range literal {
			literal[i] = n.ch
		}
		return [][]rune{literal}
	case ntLoop, ntLazyloop:
		if n.m < 1 || len(n.children) == 0 {
			return nil
		}
		return required(n.children[0])
	case ntCapture, ntGroup, ntGreedy, ntRequire:
		// A positive lookahead reads text at or after the match start, which is at or after
		// the search start.
		if len(n.children) == 0 {
			return nil
		}
		return required(n.children[0])
	case ntConcatenate:
		var best [][]rune
		for _, child := range n.children {
			if set := required(child); set != nil && (best == nil || moreSelective(set, best)) {
				best = set
			}
		}
		return best
	case ntAlternate:
		var union [][]rune
		for _, child := range n.children {
			set := required(child)
			if set == nil {
				return nil
			}
			for _, literal := range set {
				if !slices.ContainsFunc(union, func(have []rune) bool { return slices.Equal(have, literal) }) {
					union = append(union, literal)
				}
			}
			if len(union) > maxRequiredLiterals {
				return nil
			}
		}
		return union
	}
	// Sets, anchors, back-references, negative lookarounds and conditionals require no
	// literal.
	return nil
}

// moreSelective reports whether a rules out more texts than b: its shortest literal is
// longer, or as long with fewer literals.
func moreSelective(a, b [][]rune) bool {
	shortest := func(set [][]rune) int {
		n := len(set[0])
		for _, literal := range set[1:] {
			n = min(n, len(literal))
		}
		return n
	}
	if sa, sb := shortest(a), shortest(b); sa != sb {
		return sa > sb
	}
	return len(a) < len(b)
}
