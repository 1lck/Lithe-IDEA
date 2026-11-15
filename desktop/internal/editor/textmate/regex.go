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
//   - X{n,m}+ repeats the interval (Oniguruma's own syntax has no possessive interval),
//     X{n,m} with n greater than m is the possessive X{m,n}, and X{,m} is X{0,m}.
//   - The m flag lets "." match "\n" (.NET's s); "^" and "$" always match at line breaks,
//     and "^" not at the end of the text after a final line break, where .NET would.
//   - Named groups are numbered with the others, left to right, as Oniguruma numbers them
//     when it captures both; .NET numbers named groups last, so they become plain groups and
//     \k<name> a numbered back-reference.
//   - A subexpression call, \g<name> or \g<n>, is the group it calls written out again,
//     capturing into the same group; see call for how deep a group may call itself.
//   - Classes nest and intersect ([a[^b]], [a-z&&[^aeiou]]); .NET classes only subtract,
//     which charSet writes them with. POSIX brackets ([:alpha:]) and \x{...}, which may list
//     several code points, have no .NET form and are spelled out.
//   - \R, \N, \O and \X become their definitions; an unknown escaped letter is the letter.
//
// What has no translation, such as \K, a call of the whole pattern (\g<0>) or the absent
// operator, is an error, so the rule that uses it never matches.
type translator struct {
	src []rune
	pos int
	// end is where in src translating stops: the end of the pattern, or of the group a call
	// writes out.
	end int
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

	// spans are the capturing groups of the pattern by number, and numbers the numbers of the
	// groups by where their "(" is in src. A group may be called before it opens, so calls are
	// written out in a second pass, with the spans of the first.
	spans   map[int]groupSpan
	numbers map[int]int
	// resolved says spans holds every group of the pattern; called that a call was read while
	// it did not.
	resolved, called bool
	// calls are the groups being written out for calls, outermost first. Inside one, capturing
	// groups keep the numbers they have in the pattern.
	calls []int
	// depth is how many times a group may be written out within itself.
	depth int
}

// frame is one open group.
type frame struct {
	// start is where the group's "(" is in out.
	start int
	// extended is the x flag outside the group, restored when it closes.
	extended bool
	// group is the number of the capturing group the frame is, or 0, and source where its "("
	// is in src.
	group, source int
}

// groupSpan is where a capturing group is in src, from its "(" to past its ")", and whether
// the x flag is on where it opens.
type groupSpan struct {
	start, end int
	extended   bool
}

// callDepth is how many times a group may be written out within itself, so how deeply the
// brackets a recursive group matches may nest: C++ templates and Go type parameters nest a few
// levels at most. maxTranslated bounds the size of a pattern with calls: past it, groups are
// written out within themselves fewer times.
const (
	callDepth     = 6
	maxTranslated = 1 << 16
)

// translate returns source in .NET syntax, or why it has none.
func translate(source string, noA, noG bool) (string, error) {
	t := newTranslator(source, noA, noG)
	err := t.run()
	for depth := callDepth; err == nil && t.called; depth-- {
		spans, numbers, names := t.spans, t.numbers, t.names
		t = newTranslator(source, noA, noG)
		t.spans, t.numbers, t.names, t.resolved, t.depth = spans, numbers, names, true, depth
		err = t.run()
		if err == nil && (len(t.out) <= maxTranslated || depth == 1) {
			break
		}
	}
	if err != nil {
		return "", fmt.Errorf("%w in %q", err, source)
	}
	return string(t.out), nil
}

func newTranslator(source string, noA, noG bool) *translator {
	src := []rune(source)
	return &translator{src: src, end: len(src), out: make([]rune, 0, len(source)+8), atom: -1, noA: noA, noG: noG}
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
	for t.pos < t.end {
		c := t.src[t.pos]
		switch {
		case t.extended && unicode.IsSpace(c):
			t.out = append(t.out, c)
			t.pos++
		case t.extended && c == '#':
			for t.pos < t.end && t.src[t.pos] != '\n' {
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
			if last.group > 0 && !t.resolved {
				if t.spans == nil {
					t.spans, t.numbers = map[int]groupSpan{}, map[int]int{}
				}
				t.spans[last.group] = groupSpan{start: last.source, end: t.pos, extended: last.extended}
				t.numbers[last.source] = last.group
			}
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
	t.pos = end + 1
	if lo, err1 := strconv.Atoi(low); comma && high != "" && err1 == nil {
		if hi, err2 := strconv.Atoi(high); err2 == nil && lo > hi {
			// Oniguruma's possessive interval: X{n,m} with n greater than m is (?>X{m,n}).
			t.write("{" + high + "," + low + "}")
			t.wrap("(?>")
			return
		}
	}
	if comma {
		t.write("{" + low + "," + high + "}")
	} else {
		t.write("{" + low + "}")
	}
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
	// capture opens a capturing group whose "(" and name take skip runes.
	capture := func(skip int) {
		t.groups++
		number := t.groups
		text := "("
		if len(t.calls) > 0 {
			// In a group written out for a call, groups capture into their own numbers.
			number = t.numbers[t.pos]
			text = "(?<" + strconv.Itoa(number) + ">"
		}
		t.frames = append(t.frames, frame{start: start, extended: t.extended, group: number, source: t.pos})
		t.write(text)
		t.pos += skip
	}
	if t.peek(1) != '?' {
		capture(1)
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
		if t.names == nil {
			t.names = map[string]int{}
		}
		if !t.resolved {
			t.names[name] = t.groups + 1
		}
		capture(3 + length + 1)
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
	case next == 'g':
		return t.call()
	case next == 'x' || next == 'o' || next == 'u':
		runes, length, err := t.codePoints()
		if err != nil {
			return err
		}
		if len(runes) > 1 {
			t.write("(?:")
		}
		for _, r := range runes {
			t.write(literal(r))
		}
		if len(runes) > 1 {
			t.write(")")
		}
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
	case next == 'K' || next == 'y' || next == 'Y':
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

// call reads a subexpression call at pos, \g<name>, \g'name', \g<n>, \g<-n> or \g<+n>, and
// writes the group it calls in its place. Oniguruma matches the group's pattern there, within
// the group itself when the call is in it; .NET has no calls, so the group is written out
// again, its groups capturing into their own numbers as Oniguruma's do. A group written out
// within itself t.depth times calls itself no further: that call never matches.
func (t *translator) call() error {
	closing := '>'
	switch t.peek(2) {
	case '<':
	case '\'':
		closing = '\''
	default:
		return fmt.Errorf(`bad \g`)
	}
	end := t.pos + 3
	for end < len(t.src) && t.src[end] != closing {
		end++
	}
	if end == len(t.src) {
		return fmt.Errorf(`unterminated \g`)
	}
	at, name := t.pos, string(t.src[t.pos+3:end])
	t.pos = end + 1
	t.atom = len(t.out)
	if !t.resolved {
		// The group may not have been read yet: the second pass writes the call.
		t.called = true
		t.write(`(?!)`)
		return nil
	}
	number, ok := t.names[name]
	if !ok {
		n, err := strconv.Atoi(name)
		switch {
		case err != nil:
			return fmt.Errorf(`unknown group in \g<%s>`, name)
		case name[0] == '-':
			n += t.groupsBefore(at) + 1
		case name[0] == '+':
			n += t.groupsBefore(at)
		case n == 0:
			return fmt.Errorf(`unsupported \g<0>`)
		}
		number = n
	}
	span, ok := t.spans[number]
	if !ok {
		return fmt.Errorf(`unknown group in \g<%s>`, name)
	}
	depth := 0
	for _, called := range t.calls {
		if called == number {
			depth++
		}
	}
	if depth >= t.depth {
		t.write(`(?!)`)
		return nil
	}
	sub := &translator{
		src: t.src, pos: span.start, end: span.end, out: t.out, atom: -1, names: t.names,
		extended: span.extended, noA: t.noA, noG: t.noG, spans: t.spans, numbers: t.numbers,
		resolved: true, calls: append(t.calls[:len(t.calls):len(t.calls)], number), depth: t.depth,
	}
	err := sub.run()
	t.out = sub.out
	return err
}

// groupsBefore is the number of capturing groups that open before at in src.
func (t *translator) groupsBefore(at int) int {
	n := 0
	for source := range t.numbers {
		if source < at {
			n++
		}
	}
	return n
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

// codePoints reads \xHH, \x{H...}, \uHHHH or \o{O...} at pos and returns the characters and
// the escape's length. Oniguruma lets the braces list several code points, separated by
// spaces.
func (t *translator) codePoints() ([]rune, int, error) {
	kind := t.peek(1)
	var fields []string
	base, length := 16, 2
	switch {
	case t.peek(2) == '{':
		end := t.pos + 3
		for end < len(t.src) && t.src[end] != '}' {
			end++
		}
		if end == len(t.src) {
			return nil, 0, fmt.Errorf("unterminated \\%c{", kind)
		}
		fields = strings.Fields(string(t.src[t.pos+3 : end]))
		length = end + 1 - t.pos
		if kind == 'o' {
			base = 8
		}
	case kind == 'o':
		return nil, 0, fmt.Errorf(`bad \o`)
	default:
		limit := 2
		if kind == 'u' {
			limit = 4
		}
		end := t.pos + 2
		for end < len(t.src) && end-t.pos-2 < limit && strings.ContainsRune("0123456789abcdefABCDEF", t.src[end]) {
			end++
		}
		fields = []string{string(t.src[t.pos+2 : end])}
		length = end - t.pos
	}
	if len(fields) == 0 {
		return nil, 0, fmt.Errorf("bad code point in \\%c{}", kind)
	}
	runes := make([]rune, len(fields))
	for i, digits := range fields {
		value, err := strconv.ParseUint(digits, base, 32)
		if err != nil || value > unicode.MaxRune {
			return nil, 0, fmt.Errorf("bad code point %q", digits)
		}
		runes[i] = rune(value)
	}
	return runes, length, nil
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
	"alpha":     `\p{L}\p{M}`,
	"alnum":     `\p{L}\p{M}\p{Nd}`,
	"digit":     `0-9`,
	"upper":     `\p{Lu}`,
	"lower":     `\p{Ll}`,
	"space":     `\s`,
	"blank":     ` \t`,
	"word":      `\w`,
	"punct":     `\p{P}`,
	"xdigit":    `0-9A-Fa-f`,
	"cntrl":     `\p{Cc}`,
	"surrogate": `\p{Cs}`,
	"print":     `\P{C}`,
	"graph":     `\x21-\x7E\u00A1-\uFFFF`,
	"ascii":     `\x00-\x7F`,
	"any":       `\s\S`,
	"han":       `\u2E80-\u2FDF\u3005\u3007\u3021-\u3029\u3038-\u303B\u3400-\u4DBF\u4E00-\u9FFF\uF900-\uFAFF`,
	"hiragana":  `\u3041-\u309F`,
	"katakana":  `\u30A0-\u30FF`,
	"latin":     `A-Za-z\u00AA\u00BA\u00C0-\u00D6\u00D8-\u00F6\u00F8-\u024F`,
	"greek":     `\u0370-\u03FF`,
	"cyrillic":  `\u0400-\u04FF`,
}

// class reads a character class at pos.
func (t *translator) class() error {
	set, err := t.classSet()
	if err != nil {
		return err
	}
	t.write(set.String())
	return nil
}

// classSet reads a character class at pos, up to and past the "]" that closes it. An
// Oniguruma class is the intersection of its operands, separated by "&&", and an operand the
// union of what it lists, which may be classes again: [a-z&&[^aeiou]] holds the consonants and
// [\x85[^\p{Cc}]] all characters but the controls other than U+0085.
func (t *translator) classSet() (*charSet, error) {
	t.pos++
	negated := t.peek(0) == '^'
	if negated {
		t.pos++
	}
	var (
		// items are the characters, ranges and escapes of the operand being read, sets
		// what else it holds, and result the intersection of the operands before it.
		items  []rune
		sets   = &charSet{}
		result *charSet
	)
	endOperand := func() {
		operand := union(&charSet{items: literalTrailingHyphen(string(items))}, sets)
		items, sets = items[:0], &charSet{}
		if result == nil {
			result = operand
		} else {
			result = intersect(result, operand)
		}
	}
	for first := true; ; first = false {
		if t.pos >= len(t.src) {
			return nil, fmt.Errorf("unterminated class")
		}
		c := t.src[t.pos]
		switch {
		case c == ']' && !first:
			t.pos++
			endOperand()
			if negated {
				return complement(result), nil
			}
			return result, nil
		case c == ']':
			items = append(items, '\\', ']')
			t.pos++
		case c == '[' && t.peek(1) == ':':
			end := t.pos + 2
			not := t.peek(2) == '^'
			if not {
				end++
			}
			nameStart := end
			for end < len(t.src) && t.src[end] >= 'a' && t.src[end] <= 'z' {
				end++
			}
			body, ok := propertyNames[string(t.src[nameStart:end])]
			if !ok || end+1 >= len(t.src) || t.src[end] != ':' || t.src[end+1] != ']' {
				return nil, fmt.Errorf("unsupported POSIX bracket")
			}
			if not {
				sets = union(sets, complement(&charSet{items: body}))
			} else {
				items = append(items, []rune(body)...)
			}
			t.pos = end + 2
		case c == '[':
			nested, err := t.classSet()
			if err != nil {
				return nil, err
			}
			sets = union(sets, nested)
		case c == '&' && t.peek(1) == '&':
			t.pos += 2
			endOperand()
		case c == '\\':
			text, set, err := t.classEscape()
			if err != nil {
				return nil, err
			}
			if set != nil {
				sets = union(sets, set)
			}
			items = append(items, []rune(text)...)
		default:
			items = append(items, c)
			t.pos++
		}
	}
}

// classEscape reads a "\" at pos inside a class and returns what it adds to the class: text
// to write in it, or a set it has no text for.
func (t *translator) classEscape() (string, *charSet, error) {
	next := t.peek(1)
	text := ""
	switch {
	case t.pos+1 >= len(t.src):
		return "", nil, fmt.Errorf("trailing backslash")
	case next == 'h':
		text = "0-9a-fA-F"
	case next == 'H':
		t.pos += 2
		return "", &charSet{negated: true, items: "0-9a-fA-F"}, nil
	case next == 'R' || next == 'X' || next == 'N' || next == 'O':
		return "", nil, fmt.Errorf(`unsupported \%c in a class`, next)
	case next == 'x' || next == 'o' || next == 'u':
		runes, length, err := t.codePoints()
		if err != nil {
			return "", nil, err
		}
		var b strings.Builder
		for _, r := range runes {
			b.WriteString(literal(r))
		}
		t.pos += length
		return b.String(), nil, nil
	case next == 'p' || next == 'P':
		body, negated, length, err := t.property()
		if err != nil {
			return "", nil, err
		}
		t.pos += length
		switch {
		case !negated:
			return body, nil, nil
		case strings.HasPrefix(body, `\p{`):
			return `\P` + body[2:], nil, nil
		}
		return "", &charSet{negated: true, items: body}, nil
	case next == 'c':
		if t.pos+2 >= len(t.src) {
			return "", nil, fmt.Errorf("bad \\c")
		}
		text = `\c` + string(t.src[t.pos+2])
		t.pos += 3
		return text, nil, nil
	case next >= '0' && next <= '7':
		end := t.pos + 1
		for end < len(t.src) && end-t.pos <= 3 && t.src[end] >= '0' && t.src[end] <= '7' {
			end++
		}
		value, _ := strconv.ParseUint(string(t.src[t.pos+1:end]), 8, 32)
		t.pos = end
		return literal(rune(value)), nil, nil
	case strings.ContainsRune("tnrfvaedDwWsSb", next):
		text = `\` + string(next)
	case next < 0x80 && unicode.IsLetter(next):
		text = string(next)
	default:
		text = literal(next)
	}
	t.pos += 2
	return text, nil, nil
}

// charSet is a set of characters as one .NET class writes it: the characters items lists, or
// every other character when negated, less the characters of sub. Items are class content in
// .NET syntax. Oniguruma's unions and intersections become subtractions:
// A∩B is A less what is not in B, and what is not in A less B is every character less A less B.
type charSet struct {
	negated bool
	items   string
	sub     *charSet
}

func (s *charSet) empty() bool { return !s.negated && s.items == "" && s.sub == nil }

// String is the set as a .NET class.
func (s *charSet) String() string {
	var b strings.Builder
	s.write(&b)
	return b.String()
}

func (s *charSet) write(b *strings.Builder) {
	items, negated := s.items, s.negated
	if items == "" {
		// .NET has no empty class: no character is every character but those of \s\S.
		items, negated = `\s\S`, !negated
	}
	b.WriteByte('[')
	if negated {
		b.WriteByte('^')
	} else if items[0] == '^' {
		b.WriteByte('\\')
	}
	b.WriteString(items)
	if s.sub != nil {
		b.WriteByte('-')
		s.sub.write(b)
	}
	b.WriteByte(']')
}

// complement is the characters not in s.
func complement(s *charSet) *charSet {
	if !s.negated && s.items == `\s\S` && s.sub != nil {
		return s.sub
	}
	if s.sub == nil {
		return &charSet{negated: !s.negated, items: s.items}
	}
	return &charSet{items: `\s\S`, sub: s}
}

// minus is the characters of a not in b.
func minus(a, b *charSet) *charSet {
	switch {
	case a.empty() || b.empty():
		return a
	case a.sub == nil:
		return &charSet{negated: a.negated, items: a.items, sub: b}
	}
	return &charSet{negated: a.negated, items: a.items, sub: union(a.sub, b)}
}

// intersect is the characters in both a and b.
func intersect(a, b *charSet) *charSet { return minus(a, complement(b)) }

// union is the characters in a or in b.
func union(a, b *charSet) *charSet {
	switch {
	case a.empty():
		return b
	case b.empty():
		return a
	case a.sub == nil && b.sub == nil && !a.negated && !b.negated:
		return &charSet{items: joinItems(a.items, b.items)}
	}
	return complement(intersect(complement(a), complement(b)))
}

// joinItems is the class content of both a and b, so that a "-" at the end of a or the start
// of b, which Oniguruma reads as itself, cannot become a range.
func joinItems(a, b string) string {
	a = literalTrailingHyphen(a)
	if strings.HasPrefix(b, "-") {
		b = `\-` + b[1:]
	}
	return a + b
}

// literalTrailingHyphen escapes a "-" that ends class content, so that nothing after it reads
// it as a range or a subtraction.
func literalTrailingHyphen(items string) string {
	if !strings.HasSuffix(items, "-") {
		return items
	}
	slashes := 0
	for i := len(items) - 2; i >= 0 && items[i] == '\\'; i-- {
		slashes++
	}
	if slashes%2 == 1 {
		return items
	}
	return items[:len(items)-1] + `\-`
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
