package textmate

import (
	"fmt"
	"strconv"
	"strings"
	"unicode"

	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/textmate/internal/regexp2"
)

// backtrackLimit bounds one search of one pattern. A pattern that backtracks without end on a
// line gives up there, as if it did not match, instead of stalling the tokenizer; the line's
// time limit (see Tokenizer) bounds the line as a whole. Oniguruma stops at ten million
// retries; a million keeps one search within about a frame (some 13 ms on an M-series core)
// and gives the same answer on every machine, which a timeout would not.
const backtrackLimit = 1_000_000

// compilePattern compiles an Oniguruma pattern, as TextMate grammars write them, for regexp2:
// translated into .NET syntax, with "^" and "$" matching at line breaks as they do in
// Oniguruma. noA and noG make \A and \G never match, as vscode-textmate does where the search
// is not at the start of the document or not at the rule's anchor.
func compilePattern(source string, noA, noG bool) (*regexp2.Regexp, error) {
	translated, err := translate(source, noA, noG)
	if err != nil {
		return nil, err
	}
	re, err := regexp2.Compile(translated, regexp2.Multiline)
	if err != nil {
		return nil, err
	}
	re.BacktrackLimit = backtrackLimit
	return re, nil
}

// translator rewrites one Oniguruma pattern into the .NET syntax regexp2 parses. The two agree
// on most of what grammars use; translate covers where they differ:
//
//   - \h and \H are hex digits and their complement.
//   - X*+, X++ and X?+ are possessive; .NET writes them (?>X*), (?>X+) and (?>X?).
//   - X{n,m}+ repeats the interval (Oniguruma's own syntax has no possessive interval), and
//     X{,m} is X{0,m}.
//   - The m flag lets "." match "\n" (.NET's s); "^" and "$" always match at line breaks,
//     and "^" not at the end of the text after a final line break, where .NET would.
//   - Named groups are numbered with the others, left to right, as Oniguruma numbers them
//     when it captures both; .NET numbers named groups last, so they become plain groups and
//     \k<name> a numbered back-reference.
//   - POSIX brackets ([:alpha:]), nested classes ([a[bc]]) and \x{...} have no .NET form and
//     are spelled out.
//   - \R, \N, \O and \X become their definitions; an unknown escaped letter is the letter.
//
// What has no translation, such as subexpression calls (\g<name>), \K, class intersection
// (&&) or the absent operator, is an error, so the rule that uses it never matches.
type translator struct {
	src []rune
	pos int
	out []rune
	// groups is the number of capturing groups opened so far.
	groups int
	// names maps a named group to its number.
	names map[string]int
	// frames are the groups open at pos, innermost last.
	frames []frame
	// extended says the x flag is on at pos: whitespace and "#" comments are not pattern.
	extended bool
	// atom is where in out the last thing a quantifier applies to starts, or -1.
	atom int
	// noA and noG replace \A and \G with what never matches.
	noA, noG bool
}

// frame is one open group.
type frame struct {
	// start is where the group's "(" is in out.
	start int
	// extended is the x flag outside the group, restored when it closes.
	extended bool
}

// translate returns source in .NET syntax, or why it has none.
func translate(source string, noA, noG bool) (string, error) {
	t := &translator{src: []rune(source), out: make([]rune, 0, len(source)+8), atom: -1, noA: noA, noG: noG}
	if err := t.run(); err != nil {
		return "", fmt.Errorf("%w in %q", err, source)
	}
	return string(t.out), nil
}

func (t *translator) peek(offset int) rune {
	if t.pos+offset < len(t.src) {
		return t.src[t.pos+offset]
	}
	return 0
}

func (t *translator) write(s string) {
	t.out = append(t.out, []rune(s)...)
}

func (t *translator) run() error {
	for t.pos < len(t.src) {
		c := t.src[t.pos]
		switch {
		case t.extended && unicode.IsSpace(c):
			t.out = append(t.out, c)
			t.pos++
		case t.extended && c == '#':
			for t.pos < len(t.src) && t.src[t.pos] != '\n' {
				t.out = append(t.out, t.src[t.pos])
				t.pos++
			}
		case c == '\\':
			if err := t.escape(); err != nil {
				return err
			}
		case c == '[':
			t.atom = len(t.out)
			if err := t.class(); err != nil {
				return err
			}
		case c == '(':
			if err := t.open(); err != nil {
				return err
			}
		case c == ')':
			if len(t.frames) == 0 {
				return fmt.Errorf("unbalanced )")
			}
			last := t.frames[len(t.frames)-1]
			t.frames = t.frames[:len(t.frames)-1]
			t.out = append(t.out, ')')
			t.pos++
			t.atom, t.extended = last.start, last.extended
		case c == '*' || c == '+' || c == '?':
			t.out = append(t.out, c)
			t.pos++
			t.quantified()
		case c == '{':
			t.interval()
		case c == '|':
			t.out = append(t.out, c)
			t.pos++
			t.atom = -1
		case c == '^':
			// Oniguruma's "^" does not match at the end of the text, even after a line break.
			t.atom = len(t.out)
			t.write(`(?:^(?!\z))`)
			t.pos++
		default:
			t.atom = len(t.out)
			t.out = append(t.out, c)
			t.pos++
		}
	}
	if len(t.frames) > 0 {
		return fmt.Errorf("unbalanced (")
	}
	return nil
}

// quantified reads what may follow a quantifier just written: "?" makes it lazy, "+" makes it
// possessive.
func (t *translator) quantified() {
	switch t.peek(0) {
	case '?':
		t.out = append(t.out, '?')
		t.pos++
	case '+':
		t.pos++
		t.wrap("(?>")
	}
	t.atom = -1
}

// wrap puts the last atom and the quantifier after it into a group that opens with open.
func (t *translator) wrap(open string) {
	if t.atom < 0 {
		return
	}
	at := t.atom
	head := []rune(open)
	t.out = append(t.out[:at], append(head, t.out[at:]...)...)
	t.out = append(t.out, ')')
	t.atom = at
}

// interval reads a "{" at pos: a quantifier when it is {n}, {n,}, {n,m} or {,m}, a literal
// brace otherwise.
func (t *translator) interval() {
	end := t.pos + 1
	for end < len(t.src) && (t.src[end] >= '0' && t.src[end] <= '9' || t.src[end] == ',') {
		end++
	}
	body := string(t.src[t.pos+1 : end])
	low, high, comma := strings.Cut(body, ",")
	valid := end < len(t.src) && t.src[end] == '}' && body != "" && body != "," &&
		!strings.Contains(high, ",") && (low != "" || comma) && t.atom >= 0
	if !valid {
		t.write(`\{`)
		t.pos++
		t.atom = len(t.out) - 2
		return
	}
	if low == "" {
		low = "0"
	}
	if comma {
		t.write("{" + low + "," + high + "}")
	} else {
		t.write("{" + low + "}")
	}
	t.pos = end + 1
	switch t.peek(0) {
	case '?':
		t.out = append(t.out, '?')
		t.pos++
		t.atom = -1
	case '+':
		// Oniguruma repeats the interval; the "+" is read next as a quantifier of the group.
		t.wrap("(?:")
	default:
		t.atom = -1
	}
}

// open reads a "(" at pos.
func (t *translator) open() error {
	start := len(t.out)
	push := func(text string, skip int) {
		t.frames = append(t.frames, frame{start: start, extended: t.extended})
		t.write(text)
		t.pos += skip
	}
	if t.peek(1) != '?' {
		t.groups++
		push("(", 1)
		return nil
	}
	switch c := t.peek(2); {
	case c == ':' || c == '=' || c == '!' || c == '>':
		push("(?"+string(c), 3)
	case c == '<' && (t.peek(3) == '=' || t.peek(3) == '!'):
		push("(?<"+string(t.peek(3)), 4)
	case c == '<' || c == '\'':
		closing := '>'
		if c == '\'' {
			closing = '\''
		}
		name, length := t.name(3, closing)
		if name == "" {
			return fmt.Errorf("bad group name")
		}
		t.groups++
		if t.names == nil {
			t.names = map[string]int{}
		}
		t.names[name] = t.groups
		push("(", 3+length+1)
	case c == '#':
		for t.pos < len(t.src) && t.src[t.pos] != ')' {
			t.out = append(t.out, t.src[t.pos])
			t.pos++
		}
		if t.pos == len(t.src) {
			return fmt.Errorf("unterminated comment")
		}
		t.out = append(t.out, ')')
		t.pos++
	case c == '(':
		return t.condition(start)
	case c == 'i' || c == 'm' || c == 'x' || c == '-':
		return t.flags(start)
	default:
		return fmt.Errorf("unsupported group (?%c", c)
	}
	return nil
}

// name reads a group name that starts offset runes after pos and ends at closing, and returns
// it with its length.
func (t *translator) name(offset int, closing rune) (string, int) {
	end := t.pos + offset
	for end < len(t.src) && t.src[end] != closing {
		r := t.src[end]
		if !unicode.IsLetter(r) && !unicode.IsDigit(r) && r != '_' && r != '-' {
			return "", 0
		}
		end++
	}
	if end == len(t.src) {
		return "", 0
	}
	return string(t.src[t.pos+offset : end]), end - t.pos - offset
}

// condition reads a conditional group (?(cond)yes|no), its condition a group number or name.
func (t *translator) condition(start int) error {
	end := t.pos + 3
	for end < len(t.src) && t.src[end] != ')' {
		end++
	}
	if end == len(t.src) {
		return fmt.Errorf("unterminated condition")
	}
	cond := string(t.src[t.pos+3 : end])
	if strings.HasPrefix(cond, "<") && strings.HasSuffix(cond, ">") ||
		strings.HasPrefix(cond, "'") && strings.HasSuffix(cond, "'") {
		number, ok := t.names[cond[1:len(cond)-1]]
		if !ok {
			return fmt.Errorf("unknown group %s", cond)
		}
		cond = strconv.Itoa(number)
	}
	if _, err := strconv.Atoi(cond); err != nil {
		return fmt.Errorf("unsupported condition %s", cond)
	}
	t.frames = append(t.frames, frame{start: start, extended: t.extended})
	t.write("(?(" + cond + ")")
	t.pos = end + 1
	return nil
}

// flags reads an option group, (?imx-imx) for the rest of the group it is in or (?imx-imx:...)
// for its own content.
func (t *translator) flags(start int) error {
	end := t.pos + 2
	var b strings.Builder
	on, extended := true, t.extended
	for ; end < len(t.src) && t.src[end] != ')' && t.src[end] != ':'; end++ {
		switch f := t.src[end]; f {
		case '-':
			on = false
			b.WriteRune('-')
		case 'i', 'x':
			b.WriteRune(f)
			if f == 'x' {
				extended = on
			}
		case 'm':
			b.WriteRune('s')
		default:
			return fmt.Errorf("unsupported option %c", f)
		}
	}
	if end == len(t.src) {
		return fmt.Errorf("unterminated option group")
	}
	if t.src[end] == ')' {
		t.write("(?" + b.String() + ")")
		t.extended = extended
		t.pos = end + 1
		return nil
	}
	t.frames = append(t.frames, frame{start: start, extended: t.extended})
	t.write("(?" + b.String() + ":")
	t.extended = extended
	t.pos = end + 1
	return nil
}

// escape reads a "\" at pos outside a class.
func (t *translator) escape() error {
	next := t.peek(1)
	start := len(t.out)
	t.atom = start
	switch {
	case t.pos+1 >= len(t.src):
		return fmt.Errorf("trailing backslash")
	case next == 'h':
		t.write("[0-9a-fA-F]")
	case next == 'H':
		t.write("[^0-9a-fA-F]")
	case next == 'R':
		t.write(`(?:\r\n|[\n\v\f\r\u0085\u2028\u2029])`)
	case next == 'N':
		t.write(`[^\n]`)
	case next == 'O':
		t.write(`(?s:.)`)
	case next == 'X':
		t.write(`(?>\P{M}\p{M}*)`)
	case next == 'k':
		return t.backReference()
	case next == 'x' || next == 'o' || next == 'u':
		r, length, err := t.codePoint()
		if err != nil {
			return err
		}
		t.write(literal(r))
		t.pos += length
		return nil
	case next == 'p' || next == 'P':
		body, negated, length, err := t.property()
		if err != nil {
			return err
		}
		if negated {
			t.write("[^" + body + "]")
		} else {
			t.write("[" + body + "]")
		}
		t.pos += length
		return nil
	case next == 'Q':
		end := t.pos + 2
		for end < len(t.src) && !(t.src[end] == '\\' && end+1 < len(t.src) && t.src[end+1] == 'E') {
			t.write(literal(t.src[end]))
			end++
		}
		t.pos = min(end+2, len(t.src))
		return nil
	case next == 'c':
		if t.pos+2 >= len(t.src) {
			return fmt.Errorf("bad \\c")
		}
		t.write(`\c` + string(t.src[t.pos+2]))
		t.pos += 3
		return nil
	case next >= '0' && next <= '9':
		end := t.pos + 1
		for end < len(t.src) && t.src[end] >= '0' && t.src[end] <= '9' {
			end++
		}
		t.write(`\` + string(t.src[t.pos+1:end]))
		t.pos = end
		return nil
	case next == 'A' && t.noA, next == 'G' && t.noG:
		t.write(`(?!)`)
	case strings.ContainsRune("tnrfvaedDwWsSbBAzZG", next):
		t.write(`\` + string(next))
	case next == 'K' || next == 'g' || next == 'y' || next == 'Y':
		return fmt.Errorf(`unsupported \%c`, next)
	case next < 0x80 && unicode.IsLetter(next):
		// Oniguruma reads an escaped letter it does not know as the letter.
		t.out = append(t.out, next)
	default:
		t.write(literal(next))
	}
	t.pos += 2
	return nil
}

// backReference reads \k<name>, \k'name' or \k<n> as a numbered back-reference.
func (t *translator) backReference() error {
	closing := '>'
	switch t.peek(2) {
	case '<':
	case '\'':
		closing = '\''
	default:
		return fmt.Errorf(`bad \k`)
	}
	end := t.pos + 3
	for end < len(t.src) && t.src[end] != closing {
		end++
	}
	if end == len(t.src) {
		return fmt.Errorf(`unterminated \k`)
	}
	name := string(t.src[t.pos+3 : end])
	number, ok := t.names[name]
	if !ok {
		n, err := strconv.Atoi(name)
		if err != nil || n <= 0 {
			return fmt.Errorf(`unsupported \k<%s>`, name)
		}
		number = n
	}
	t.write(`\` + strconv.Itoa(number))
	t.pos = end + 1
	return nil
}

// codePoint reads \xHH, \x{H...}, \uHHHH or \o{O...} at pos and returns the character and the
// escape's length.
func (t *translator) codePoint() (rune, int, error) {
	kind := t.peek(1)
	digits, base, length := "", 16, 2
	switch {
	case t.peek(2) == '{':
		end := t.pos + 3
		for end < len(t.src) && t.src[end] != '}' {
			end++
		}
		if end == len(t.src) {
			return 0, 0, fmt.Errorf("unterminated \\%c{", kind)
		}
		digits = string(t.src[t.pos+3 : end])
		length = end + 1 - t.pos
		if kind == 'o' {
			base = 8
		}
	case kind == 'o':
		return 0, 0, fmt.Errorf(`bad \o`)
	default:
		limit := 2
		if kind == 'u' {
			limit = 4
		}
		end := t.pos + 2
		for end < len(t.src) && end-t.pos-2 < limit && strings.ContainsRune("0123456789abcdefABCDEF", t.src[end]) {
			end++
		}
		digits = string(t.src[t.pos+2 : end])
		length = end - t.pos
	}
	value, err := strconv.ParseUint(digits, base, 32)
	if err != nil || value > unicode.MaxRune {
		return 0, 0, fmt.Errorf("bad code point %q", digits)
	}
	return rune(value), length, nil
}

// property reads \p{Name}, \p{^Name} or \P{Name} at pos and returns what a class holds for it.
func (t *translator) property() (body string, negated bool, length int, err error) {
	if t.peek(2) != '{' {
		return "", false, 0, fmt.Errorf(`bad \p`)
	}
	end := t.pos + 3
	for end < len(t.src) && t.src[end] != '}' {
		end++
	}
	if end == len(t.src) {
		return "", false, 0, fmt.Errorf(`unterminated \p{`)
	}
	name := string(t.src[t.pos+3 : end])
	negated = t.peek(1) == 'P'
	if strings.HasPrefix(name, "^") {
		negated, name = !negated, name[1:]
	}
	key := strings.ToLower(strings.NewReplacer(" ", "", "_", "", "-", "").Replace(name))
	if mapped, ok := propertyNames[key]; ok {
		return mapped, negated, end + 1 - t.pos, nil
	}
	return `\p{` + name + `}`, negated, end + 1 - t.pos, nil
}

// propertyNames are the Oniguruma property and POSIX bracket names .NET does not know, as the
// content of a class.
var propertyNames = map[string]string{
	"alpha":    `\p{L}\p{M}`,
	"alnum":    `\p{L}\p{M}\p{Nd}`,
	"digit":    `0-9`,
	"upper":    `\p{Lu}`,
	"lower":    `\p{Ll}`,
	"space":    `\s`,
	"blank":    ` \t`,
	"word":     `\w`,
	"punct":    `\p{P}`,
	"xdigit":   `0-9A-Fa-f`,
	"cntrl":    `\p{Cc}`,
	"print":    `\P{C}`,
	"graph":    `\x21-\x7E\u00A1-\uFFFF`,
	"ascii":    `\x00-\x7F`,
	"any":      `\s\S`,
	"han":      `\u2E80-\u2FDF\u3005\u3007\u3021-\u3029\u3038-\u303B\u3400-\u4DBF\u4E00-\u9FFF\uF900-\uFAFF`,
	"hiragana": `\u3041-\u309F`,
	"katakana": `\u30A0-\u30FF`,
	"latin":    `A-Za-z\u00AA\u00BA\u00C0-\u00D6\u00D8-\u00F6\u00F8-\u024F`,
	"greek":    `\u0370-\u03FF`,
	"cyrillic": `\u0400-\u04FF`,
}

// class reads a character class at pos.
func (t *translator) class() error {
	t.out = append(t.out, '[')
	t.pos++
	if t.peek(0) == '^' {
		t.out = append(t.out, '^')
		t.pos++
	}
	if err := t.classBody(); err != nil {
		return err
	}
	t.out = append(t.out, ']')
	return nil
}

// classBody reads the content of a class up to and past the "]" that closes it, writing the
// content without that bracket.
func (t *translator) classBody() error {
	for first := true; ; first = false {
		if t.pos >= len(t.src) {
			return fmt.Errorf("unterminated class")
		}
		c := t.src[t.pos]
		switch {
		case c == ']' && !first:
			t.pos++
			return nil
		case c == ']':
			t.write(`\]`)
			t.pos++
		case c == '[' && t.peek(1) == ':':
			end := t.pos + 2
			for end < len(t.src) && t.src[end] >= 'a' && t.src[end] <= 'z' {
				end++
			}
			body, ok := propertyNames[string(t.src[t.pos+2:end])]
			if !ok || end+1 >= len(t.src) || t.src[end] != ':' || t.src[end+1] != ']' {
				return fmt.Errorf("unsupported POSIX bracket")
			}
			t.write(body)
			t.pos = end + 2
		case c == '[':
			// A nested class is a union; only a plain one can be spelled out in .NET.
			if t.peek(1) == '^' {
				return fmt.Errorf("unsupported negated nested class")
			}
			t.pos++
			if err := t.classBody(); err != nil {
				return err
			}
		case c == '&' && t.peek(1) == '&':
			return fmt.Errorf("unsupported class intersection")
		case c == '\\':
			if err := t.classEscape(); err != nil {
				return err
			}
		default:
			t.out = append(t.out, c)
			t.pos++
		}
	}
}

// classEscape reads a "\" at pos inside a class.
func (t *translator) classEscape() error {
	next := t.peek(1)
	switch {
	case t.pos+1 >= len(t.src):
		return fmt.Errorf("trailing backslash")
	case next == 'h':
		t.write("0-9a-fA-F")
	case next == 'H' || next == 'R' || next == 'X' || next == 'N' || next == 'O':
		return fmt.Errorf(`unsupported \%c in a class`, next)
	case next == 'x' || next == 'o' || next == 'u':
		r, length, err := t.codePoint()
		if err != nil {
			return err
		}
		t.write(literal(r))
		t.pos += length
		return nil
	case next == 'p' || next == 'P':
		body, negated, length, err := t.property()
		if err != nil {
			return err
		}
		if negated {
			if !strings.HasPrefix(body, `\p{`) {
				return fmt.Errorf("unsupported negated property in a class")
			}
			body = `\P` + body[2:]
		}
		t.write(body)
		t.pos += length
		return nil
	case next == 'c':
		if t.pos+2 >= len(t.src) {
			return fmt.Errorf("bad \\c")
		}
		t.write(`\c` + string(t.src[t.pos+2]))
		t.pos += 3
		return nil
	case next >= '0' && next <= '7':
		end := t.pos + 1
		for end < len(t.src) && end-t.pos <= 3 && t.src[end] >= '0' && t.src[end] <= '7' {
			end++
		}
		value, _ := strconv.ParseUint(string(t.src[t.pos+1:end]), 8, 32)
		t.write(literal(rune(value)))
		t.pos = end
		return nil
	case strings.ContainsRune("tnrfvaedDwWsSb", next):
		t.write(`\` + string(next))
	case next < 0x80 && unicode.IsLetter(next):
		t.out = append(t.out, next)
	default:
		t.write(literal(next))
	}
	t.pos += 2
	return nil
}

// literal is r as a pattern that matches only r, inside a class or out. A digit is spelled as
// its code, so that it cannot join a back-reference written before it.
func literal(r rune) string {
	switch {
	case r < 0x20 || r == 0x7F || r >= '0' && r <= '9':
		return fmt.Sprintf(`\x%02X`, r)
	case r < 0x80 && !unicode.IsLetter(r) && !unicode.IsDigit(r) && r != ' ' && r != '_':
		return `\` + string(r)
	case r == ' ':
		return `\x20`
	}
	return string(r)
}

// escapeLiteral is text as a pattern that matches it, as vscode-textmate escapes the text a
// back-reference in an end pattern stands for.
func escapeLiteral(text string) string {
	var b strings.Builder
	for _, r := range text {
		if strings.ContainsRune(`-\{}*+?|^$.,[]()#`, r) || unicode.IsSpace(r) {
			b.WriteByte('\\')
		}
		b.WriteRune(r)
	}
	return b.String()
}
