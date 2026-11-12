package syntax

import (
	"errors"
	"slices"
	"strings"
	"unicode/utf8"

	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/rope"
)

// SemanticTypes are the semantic token types themes style, in the previous editor's legend
// order. A semantic token's name is its type followed by its modifiers, dot-separated, in
// SemanticModifiers order: "method.declaration.static".
var SemanticTypes = []string{
	"namespace", "type", "class", "enum", "interface", "struct", "typeParameter", "parameter",
	"variable", "property", "enumMember", "event", "function", "method", "macro", "label",
	"comment", "string", "keyword", "modifier", "number", "regexp", "operator", "decorator",
	"boolean", "null", "constant", "attribute",
}

// SemanticModifiers are the semantic token modifiers themes style; a server's other
// modifiers are ignored.
var SemanticModifiers = []string{"readonly", "deprecated", "declaration", "static"}

// semanticAliases maps the types language servers report under other names, normalized by
// normalizeSemantic, to one of SemanticTypes.
var semanticAliases = map[string]string{
	"annotation": "attribute", "bool": "boolean", "builtinattribute": "attribute",
	"builtinconstant": "constant", "builtinfunction": "function", "builtinmodule": "namespace",
	"builtintype": "type", "character": "string", "constparameter": "parameter",
	"derive": "attribute", "derivehelper": "function", "escapesequence": "string",
	"field": "property", "formatspecifier": "string", "generic": "typeParameter",
	"lifetime": "label", "selfkeyword": "keyword", "toolmodule": "namespace",
	"typealias": "type", "union": "type",
}

// normalizeSemantic lowercases name and drops '-', '_' and white space, so that
// "type_parameter", "Type-Parameter" and "typeParameter" are the same name.
func normalizeSemantic(name string) string {
	var b strings.Builder
	for _, r := range name {
		switch r {
		case '-', '_', ' ', '\t', '\n', '\r':
			continue
		}
		b.WriteString(strings.ToLower(string(r)))
	}
	return b.String()
}

// semanticTypeIndex returns the index in SemanticTypes of a server's type: the type itself,
// else its alias, else a type equal to it once both are normalized.
func semanticTypeIndex(name string) (int, bool) {
	if i := slices.Index(SemanticTypes, name); i >= 0 {
		return i, true
	}
	normal := normalizeSemantic(name)
	if alias, ok := semanticAliases[normal]; ok {
		return slices.Index(SemanticTypes, alias), true
	}
	for i, t := range SemanticTypes {
		if normalizeSemantic(t) == normal {
			return i, true
		}
	}
	return 0, false
}

// semanticNames holds the Name of every type and modifier set, by type index and modifier
// bits in SemanticModifiers order.
var semanticNames = func() [][]Name {
	names := make([][]Name, len(SemanticTypes))
	for i, t := range SemanticTypes {
		names[i] = make([]Name, 1<<len(SemanticModifiers))
		for bits := range names[i] {
			token := t
			for m, modifier := range SemanticModifiers {
				if bits&(1<<m) != 0 {
					token += "." + modifier
				}
			}
			names[i][bits] = Intern(token)
		}
	}
	return names
}()

// SemanticLegend translates a language server's semantic token legend into token names.
// It never changes and is safe for concurrent use.
type SemanticLegend struct {
	// types holds, by the server's type index, one more than the index in SemanticTypes, or 0
	// for a type no theme styles.
	types []uint8
	// modifiers holds, by the server's modifier bit, the bit in SemanticModifiers order.
	modifiers [32]uint8
}

// NewSemanticLegend returns the legend of a server that reports tokenTypes and
// tokenModifiers.
func NewSemanticLegend(tokenTypes, tokenModifiers []string) *SemanticLegend {
	l := &SemanticLegend{types: make([]uint8, len(tokenTypes))}
	for i, t := range tokenTypes {
		if index, ok := semanticTypeIndex(t); ok {
			l.types[i] = uint8(index + 1)
		}
	}
	for bit, m := range tokenModifiers {
		if bit >= len(l.modifiers) {
			break
		}
		normal := normalizeSemantic(m)
		for i, ours := range SemanticModifiers {
			if normalizeSemantic(ours) == normal {
				l.modifiers[bit] = 1 << i
			}
		}
	}
	return l
}

// Name returns the token name of a server's type index and modifier bits; false for a type
// no theme styles.
func (l *SemanticLegend) Name(tokenType, tokenModifiers uint32) (Name, bool) {
	if int64(tokenType) >= int64(len(l.types)) || l.types[tokenType] == 0 {
		return 0, false
	}
	var bits uint8
	for bit := 0; tokenModifiers != 0 && bit < len(l.modifiers); bit++ {
		if tokenModifiers&1 != 0 {
			bits |= l.modifiers[bit]
		}
		tokenModifiers >>= 1
	}
	return semanticNames[l.types[tokenType]-1][bits], true
}

// SemanticToken is one token a language server reports: its line, its start and length in
// UTF-16 code units, and its type and modifiers as indexes and bits of the server's legend.
type SemanticToken struct {
	Line, StartChar, Length uint32
	Type, Modifiers         uint32
}

// ErrSemanticData is returned for LSP semantic token data whose length is not a multiple of
// five.
var ErrSemanticData = errors.New("syntax: semantic token data is not a multiple of five integers")

// DecodeSemanticTokens decodes the relative encoding of LSP's SemanticTokens.data and appends
// the tokens to dst.
func DecodeSemanticTokens(dst []SemanticToken, data []uint32) ([]SemanticToken, error) {
	if len(data)%5 != 0 {
		return dst, ErrSemanticData
	}
	var line, start uint32
	for i := 0; i < len(data); i += 5 {
		if data[i] != 0 {
			line += data[i]
			start = 0
		}
		start += data[i+1]
		dst = append(dst, SemanticToken{Line: line, StartChar: start, Length: data[i+2], Type: data[i+3], Modifiers: data[i+4]})
	}
	return dst, nil
}

// semanticTokens are a document's semantic tokens as a flat array, four values per token:
// line, start byte and end byte in the line, and Name. They are sorted by line and start, do
// not overlap and are never empty. The array holds no pointers, so the collector does not
// scan it however many tokens a document has.
type semanticTokens []uint32

const semanticStride = 4

func (s semanticTokens) len() int { return len(s) / semanticStride }

func (s semanticTokens) token(i int) (line, start, end int, name Name) {
	t := s[i*semanticStride:]
	return int(t[0]), int(t[1]), int(t[2]), Name(t[3])
}

// lineRange returns the indexes of the first token on line and of the first token past it.
func (s semanticTokens) lineRange(line int) (int, int) {
	n := s.len()
	first := searchTokens(n, func(i int) bool { return int(s[i*semanticStride]) >= line })
	last := first + searchTokens(n-first, func(i int) bool { return int(s[(first+i)*semanticStride]) > line })
	return first, last
}

// searchTokens is sort.Search without the import: the smallest i in [0, n) with f(i), or n.
func searchTokens(n int, f func(int) bool) int {
	lo, hi := 0, n
	for lo < hi {
		mid := int(uint(lo+hi) >> 1)
		if f(mid) {
			hi = mid
		} else {
			lo = mid + 1
		}
	}
	return lo
}

// buildSemantic validates tokens against text, converts their UTF-16 positions to bytes and
// returns them sorted, with tokens that overlap an earlier one on the same line dropped. A
// token is dropped when its type is not styled, its length is 0, its line is past the text or
// it starts past its line; a token that runs past its line ends at the line's end.
func buildSemantic(text rope.Rope, legend *SemanticLegend, tokens []SemanticToken) semanticTokens {
	sorted := tokens
	if !slices.IsSortedFunc(tokens, compareSemantic) {
		sorted = slices.Clone(tokens)
		slices.SortStableFunc(sorted, compareSemantic)
	}
	out := make(semanticTokens, 0, len(sorted)*semanticStride)
	lines := text.LineCount()
	var buf []byte
	bufLine := -1
	lastLine, lastEnd := -1, 0
	for _, t := range sorted {
		if t.Length == 0 || int64(t.Line) >= int64(lines) {
			continue
		}
		name, ok := legend.Name(t.Type, t.Modifiers)
		if !ok {
			continue
		}
		line := int(t.Line)
		if line != bufLine {
			buf, bufLine = text.AppendLine(buf[:0], line), line
		}
		start, ok := utf16Offset(buf, 0, t.StartChar)
		if !ok || start >= len(buf) {
			continue
		}
		end, _ := utf16Offset(buf, start, t.Length)
		if line == lastLine && start < lastEnd {
			continue
		}
		out = append(out, uint32(line), uint32(start), uint32(end), uint32(name))
		lastLine, lastEnd = line, end
	}
	return out
}

func compareSemantic(a, b SemanticToken) int {
	if a.Line != b.Line {
		return cmpUint32(a.Line, b.Line)
	}
	return cmpUint32(a.StartChar, b.StartChar)
}

func cmpUint32(a, b uint32) int {
	switch {
	case a < b:
		return -1
	case a > b:
		return 1
	}
	return 0
}

// utf16Offset returns the byte offset in line that is units UTF-16 code units past byte
// offset from, and whether line has that many. Short of them it returns len(line). An offset
// inside a surrogate pair rounds up to the end of the character.
func utf16Offset(line []byte, from int, units uint32) (int, bool) {
	at := from
	for units > 0 {
		if at >= len(line) {
			return len(line), false
		}
		r, size := utf8.DecodeRune(line[at:])
		at += size
		if r >= 0x10000 && units >= 2 {
			units -= 2
		} else {
			units--
		}
	}
	return at, true
}

// edit moves semantic tokens across an edit that replaced the text from (startLine, startCol)
// to (endLine, endCol), in bytes, with text that has newlines line breaks and whose last line
// is lastLen bytes long (its whole length when newlines is 0). firstByte is the inserted
// text's first byte, or 0 when none was inserted. It returns s, changed in place.
//
// Until the language server answers for the new text, tokens stay where the server would
// most likely put them again, as VS Code keeps them: the edit is a deletion followed by an
// insertion; tokens before it stay, tokens after it move with the text, tokens the deletion
// covered shrink or go, a token typed into grows with the typing, and a line break typed into
// a token keeps only the token's part before it.
func (s semanticTokens) edit(startLine, startCol, endLine, endCol, newlines, lastLen int, firstByte byte) semanticTokens {
	// Tokens that end before the edit begins are untouched.
	first := searchTokens(s.len(), func(i int) bool {
		line, _, end, _ := s.token(i)
		return line > startLine || (line == startLine && end >= startCol)
	})
	out := s[:first*semanticStride]
	for i := first; i < s.len(); i++ {
		line, start, end, name := s.token(i)
		var ok bool
		if line, start, end, ok = deleteRange(line, start, end, startLine, startCol, endLine, endCol); !ok {
			continue
		}
		line, start, end = insertText(line, start, end, startLine, startCol, newlines, lastLen, firstByte)
		// Each token makes at most one, so writing never overtakes reading.
		out = append(out, uint32(line), uint32(start), uint32(end), uint32(name))
	}
	return out
}

// deleteRange moves a token across the deletion of the text from (sl, sc) to (el, ec) and
// reports whether any of it is left.
func deleteRange(line, start, end, sl, sc, el, ec int) (int, int, int, bool) {
	switch {
	case line < sl || (line == sl && end <= sc):
		return line, start, end, true
	case line > el:
		return line - (el - sl), start, end, true
	case line == el && start >= ec:
		return sl, sc + start - ec, sc + end - ec, true
	case line == sl:
		// It begins before the deletion: its part before it stays, joined by its part after
		// it when it runs past the deletion on the same line.
		newEnd := min(end, sc)
		if line == el && end > ec {
			newEnd = sc + end - ec
		}
		return line, min(start, sc), newEnd, min(start, sc) < newEnd
	case line == el && end > ec:
		// It began inside the deletion on its last line: its part after the deletion stays.
		return sl, sc, sc + end - ec, true
	}
	return 0, 0, 0, false
}

// insertText moves a token across the insertion at (sl, sc) of text with newlines line breaks
// whose last line is lastLen bytes long and whose first byte is firstByte.
func insertText(line, start, end, sl, sc, newlines, lastLen int, firstByte byte) (int, int, int) {
	switch {
	case line > sl:
		return line + newlines, start, end
	case line < sl || end < sc:
		return line, start, end
	case start >= sc:
		// At or after the insertion point: pushed along with the text after it.
		if newlines == 0 {
			return line, start + lastLen, end + lastLen
		}
		return line + newlines, start - sc + lastLen, end - sc + lastLen
	case end > sc || (newlines == 0 && isWordByte(firstByte)):
		// Typed into, or a word character typed right after it, as when an identifier is
		// being typed: the token grows, unless a line break cut it.
		if newlines == 0 {
			return line, start, end + lastLen
		}
		return line, start, min(end, sc)
	}
	return line, start, end
}

func isWordByte(b byte) bool {
	return b == '_' || b == '$' || b >= 0x80 || (b >= '0' && b <= '9') || (b|0x20 >= 'a' && b|0x20 <= 'z')
}
