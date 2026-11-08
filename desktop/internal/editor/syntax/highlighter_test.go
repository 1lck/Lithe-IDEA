package syntax

import (
	"math/rand/v2"
	"os"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/rope"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/textmate"
)

func testSyntax(t testing.TB, id string) *Syntax {
	t.Helper()
	s := NewRegistry().Syntax(id)
	if s == nil {
		t.Fatalf("no syntax for %s", id)
	}
	return s
}

func readSample(t testing.TB, name string) string {
	t.Helper()
	data, err := os.ReadFile("../textmate/testdata/" + name)
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

// reference tokenizes every line of text in order from the first, the tokens a highlighter
// must show once its checkpoints have converged.
func reference(s *Syntax, text rope.Rope) [][]uint32 {
	tz := lineTokenizer{tz: s.grammar.NewTokenizer(), names: s.names}
	out := make([][]uint32, text.LineCount())
	var state *textmate.StateStack
	for line := range out {
		tz.out = tz.out[:0]
		state = tz.tokenize(text, line, state)
		out[line] = slices.Clone(tz.out)
	}
	return out
}

func pairs(tokens []Token) []uint32 {
	out := make([]uint32, 0, 2*len(tokens))
	for _, t := range tokens {
		out = append(out, uint32(t.Start), uint32(t.Name))
	}
	return out
}

// testHighlighter returns a highlighter without a background goroutine, without a time limit
// per line, whose changes are recorded in changes.
func testHighlighter(s *Syntax, text rope.Rope, cacheLines int, changes *[][2]int) *Highlighter {
	options := HighlighterOptions{LineLimit: -1, CacheLines: cacheLines}
	if changes != nil {
		options.OnChange = func(first, last int) { *changes = append(*changes, [2]int{first, last}) }
	}
	return newHighlighter(s, text, options, false)
}

// drain runs the background work to its end and returns how many steps it took.
func drain(t testing.TB, h *Highlighter) int {
	t.Helper()
	limit := 16 + 4*h.text.LineCount()
	steps := 0
	for h.cp.firstDirty < len(h.cp.lines) {
		if steps++; steps > limit {
			t.Fatalf("checkpoints did not converge in %d steps", limit)
		}
		h.step()
	}
	if h.step() {
		t.Fatal("step reports more work with no dirty segment")
	}
	return steps
}

func checkLines(t testing.TB, h *Highlighter, want [][]uint32, first, last int) {
	t.Helper()
	var dst []Token
	for line := first; line <= last; line++ {
		dst = h.Line(dst[:0], line)
		if got := pairs(dst); !slices.Equal(got, want[line]) {
			t.Fatalf("line %d: tokens %v, want %v", line, got, want[line])
		}
	}
}

func covered(changes [][2]int, line int) bool {
	for _, c := range changes {
		if line >= c[0] && line <= c[1] {
			return true
		}
	}
	return false
}

var samples = []struct{ file, language string }{
	{"Sample.java", "java"},
	{"Makefile", "makefile"},
	{"sample.c", "c"},
	{"sample.cpp", "cpp"},
	{"sample.css", "css"},
	{"sample.env", "dotenv"},
	{"sample.go", "go"},
	{"sample.html", "html"},
	{"sample.ini", "ini"},
	{"sample.js", "javascript"},
	{"sample.json", "json"},
	{"sample.jsonc", "jsonc"},
	{"sample.jsx", "javascriptreact"},
	{"sample.md", "markdown"},
	{"sample.rs", "rust"},
	{"sample.toml", "toml"},
	{"sample.ts", "typescript"},
	{"sample.tsx", "typescriptreact"},
	{"sample.xml", "xml"},
	{"sample.yaml", "yaml"},
}

func TestHighlighterMatchesSequentialTokenization(t *testing.T) {
	for _, sample := range samples {
		t.Run(sample.file, func(t *testing.T) {
			s := testSyntax(t, sample.language)
			// Long enough that lines far down are past replaying and are guessed first.
			text := rope.FromString(strings.Repeat(readSample(t, sample.file), 8))
			want := reference(s, text)
			last := text.LineCount() - 1

			// Reading from the top, as when scrolling down, is exact with no background work.
			top := testHighlighter(s, text, 0, nil)
			checkLines(t, top, want, 0, last)

			// Lines read far down before the background work may be guessed; the work then
			// corrects them, and a fresh read of every line is exact.
			var changes [][2]int
			h := testHighlighter(s, text, 0, &changes)
			h.Prepare(last-40, last)
			drain(t, h)
			checkLines(t, h, want, 0, last)
		})
	}
}

func TestHighlighterCorrectsGuessedLines(t *testing.T) {
	s := testSyntax(t, "java")
	var b strings.Builder
	b.WriteString("class A {\n    int a; /*\n")
	for range 300 {
		b.WriteString("    int x = 1;\n")
	}
	b.WriteString("    */\n}\n")
	text := rope.FromString(b.String())
	want := reference(s, text)

	var changes [][2]int
	h := testHighlighter(s, text, 0, &changes)
	h.Prepare(250, 260)
	// The comment opens at the end of an indented line, which guessing does not look at, so
	// the guess has the lines as code.
	guessed := pairs(h.Line(nil, 250))
	if slices.Equal(guessed, want[250]) {
		t.Fatalf("line 250 guessed right (%v); the test needs a wrong guess", guessed)
	}
	if want[250][1] != uint32(Intern("comment.block.java")) {
		t.Fatalf("line 250 tokens %v, want a block comment", want[250])
	}
	drain(t, h)
	for line := 250; line <= 260; line++ {
		if !covered(changes, line) {
			t.Fatalf("line %d corrected without OnChange; reported %v", line, changes)
		}
	}
	checkLines(t, h, want, 0, text.LineCount()-1)
}

func TestHighlighterReportsChangedLines(t *testing.T) {
	s := testSyntax(t, "java")
	text := rope.FromString(strings.Repeat(readSample(t, "Sample.java"), 3))
	var changes [][2]int
	h := testHighlighter(s, text, 0, &changes)
	drain(t, h)
	h.Prepare(0, 80)

	// Opening a comment on a line on screen recolors that line at once and the lines after it
	// in the background.
	at := text.LineStart(5)
	next := text.Insert(at, []byte("/*"))
	h.Edit(next, at, at, at+2)
	want := reference(s, next)
	if got := pairs(h.Line(nil, 5)); !slices.Equal(got, want[5]) {
		t.Fatalf("edited line 5: tokens %v, want %v", got, want[5])
	}
	before := make([][]uint32, 81)
	for line := range before {
		before[line] = pairs(h.Line(nil, line))
	}
	changes = nil
	drain(t, h)
	recolored := 0
	for line := range before {
		after := pairs(h.Line(nil, line))
		if !slices.Equal(after, want[line]) {
			t.Fatalf("line %d: tokens %v, want %v", line, after, want[line])
		}
		if !slices.Equal(after, before[line]) {
			recolored++
			if !covered(changes, line) {
				t.Fatalf("line %d changed without OnChange; reported %v", line, changes)
			}
		}
	}
	if recolored == 0 {
		t.Fatal("opening a comment recolored no line after it")
	}
}

func TestHighlighterStateNeutralEditTakesOneStep(t *testing.T) {
	s := testSyntax(t, "java")
	text := rope.FromString(strings.Repeat(readSample(t, "Sample.java"), 8))
	h := testHighlighter(s, text, 0, nil)
	drain(t, h)

	at := text.LineStart(300)
	next := text.Insert(at, []byte(" "))
	h.Edit(next, at, at, at+1)
	if steps := drain(t, h); steps != 1 {
		t.Fatalf("a space at a line start took %d steps, want 1", steps)
	}
	checkLines(t, h, reference(s, next), 0, next.LineCount()-1)

	// A comment opened at the top runs to the next comment close; the states after it change
	// segment by segment until they match the old ones again.
	opened := next.Insert(0, []byte("/*"))
	h.Edit(opened, 0, 0, 2)
	drain(t, h)
	checkLines(t, h, reference(s, opened), 0, opened.LineCount()-1)
}

// runeStart moves offset back to the start of the character it is in.
func runeStart(text rope.Rope, offset int) int {
	for offset > 0 && offset < text.Len() && text.ByteAt(offset)&0xc0 == 0x80 {
		offset--
	}
	return offset
}

func TestHighlighterConvergesAfterRandomEdits(t *testing.T) {
	s := testSyntax(t, "java")
	text := rope.FromString(strings.Repeat(readSample(t, "Sample.java"), 3))
	h := testHighlighter(s, text, 64, nil)
	drain(t, h)
	rng := rand.New(rand.NewPCG(1794, 8))
	snippets := []string{"/*", "*/", "\n", "\"", "x", "// c\n", "{\n", "}\n", "/** doc */", "\n\n\n", "'", "@Override\n", `"""` + "\n"}
	for round := range 400 {
		n := text.Len()
		start := runeStart(text, rng.IntN(n+1))
		end := runeStart(text, min(n, start+rng.IntN(3)*rng.IntN(40)))
		end = max(end, start)
		insert := ""
		if rng.IntN(4) != 0 {
			insert = snippets[rng.IntN(len(snippets))]
		}
		next := text.Replace(start, end, []byte(insert))
		h.Edit(next, start, end, start+len(insert))
		text = next
		if rng.IntN(3) == 0 {
			first := rng.IntN(text.LineCount())
			h.Prepare(first, first+40)
		}
		for k := rng.IntN(4); k > 0 && h.step(); k-- {
		}
		if round%50 == 49 {
			drain(t, h)
			checkLines(t, h, reference(s, text), 0, text.LineCount()-1)
		}
	}
}

func TestHighlighterTokensLongLineAsOne(t *testing.T) {
	s := testSyntax(t, "java")
	text := rope.FromString("/*\n" + strings.Repeat("a", maxLineBytes+1) + "\n*/ int x;\n")
	h := testHighlighter(s, text, 0, nil)
	if got := h.Line(nil, 1); !slices.Equal(got, []Token{{0, 0}}) {
		t.Fatalf("long line: tokens %v, want one plain token", got)
	}
	// The line leaves the state as it found it: the comment it is in goes on after it.
	got := h.Line(nil, 2)
	if len(got) < 2 || got[0] != (Token{0, Intern("comment.block.java")}) {
		t.Fatalf("line after the long line: tokens %v, want the comment to close first", got)
	}
}

func TestHighlighterPlainText(t *testing.T) {
	text := rope.FromString("one\ntwo\n")
	h := newHighlighter(nil, text, HighlighterOptions{}, false)
	if got := h.Line(nil, 1); !slices.Equal(got, []Token{{0, 0}}) {
		t.Fatalf("plain line: tokens %v", got)
	}
	if got := h.Line(nil, 3); len(got) != 0 {
		t.Fatalf("line past the end: tokens %v", got)
	}
	next := text.Insert(3, []byte(" and"))
	h.Edit(next, 3, 3, 7)
	h.Prepare(0, 2)
	if h.step() {
		t.Fatal("plain text has background work")
	}
	// Semantic tokens color plain text too.
	legend := NewSemanticLegend([]string{"variable"}, nil)
	if !h.SetSemantic(next, legend, []SemanticToken{{Line: 0, StartChar: 4, Length: 3}}) {
		t.Fatal("SetSemantic rejected the current text")
	}
	want := []Token{{0, 0}, {4, Intern("variable")}}
	if got := h.Line(nil, 0); !slices.Equal(got, want) {
		t.Fatalf("plain line with a semantic token: tokens %v, want %v", got, want)
	}
}

func TestHighlighterSetTextAndClose(t *testing.T) {
	s := testSyntax(t, "java")
	h := testHighlighter(s, rope.FromString("class A {}\n"), 0, nil)
	drain(t, h)
	text := rope.FromString(strings.Repeat(readSample(t, "Sample.java"), 2))
	h.SetText(text)
	drain(t, h)
	want := reference(s, text)
	checkLines(t, h, want, 0, text.LineCount()-1)

	h.SetText(text.Insert(0, []byte("/*")))
	h.Close()
	if h.step() {
		t.Fatal("step works after Close")
	}
	if got := h.Line(nil, 0); len(got) == 0 {
		t.Fatal("a closed highlighter does not answer")
	}
}

func TestHighlighterBackground(t *testing.T) {
	s := testSyntax(t, "java")
	text := rope.FromString(strings.Repeat(readSample(t, "Sample.java"), 3))
	reports := make(chan [2]int, 1024)
	h := NewHighlighter(s, text, HighlighterOptions{LineLimit: -1, OnChange: func(first, last int) {
		select {
		case reports <- [2]int{first, last}:
		default:
		}
	}})
	defer h.Close()
	// Whatever the goroutine has done by now, lines 6 to 60 are cached with the tokens they
	// had before the comment opened above them, and it must recolor every one that changes.
	h.Prepare(0, 60)
	at := text.LineStart(5)
	next := text.Insert(at, []byte("/*"))
	h.Edit(next, at, at, at+2)
	old, want := reference(s, text), reference(s, next)

	deadline := time.After(10 * time.Second)
	var changes [][2]int
	recolored := 0
	for line := 6; line <= 60; {
		if slices.Equal(old[line], want[line]) || covered(changes, line) {
			if !slices.Equal(old[line], want[line]) {
				recolored++
			}
			line++
			continue
		}
		select {
		case c := <-reports:
			changes = append(changes, c)
		case <-deadline:
			t.Fatalf("line %d not recolored in time; reported %v", line, changes)
		}
	}
	if recolored == 0 {
		t.Fatal("opening a comment recolored no line after it")
	}
	checkLines(t, h, want, 0, 60)
}

func TestHighlighterSemanticOverlay(t *testing.T) {
	s := testSyntax(t, "java")
	text := rope.FromString(readSample(t, "Sample.java"))
	h := testHighlighter(s, text, 0, nil)
	drain(t, h)
	lexical := make([][]Token, text.LineCount())
	for line := range lexical {
		lexical[line] = h.Line(nil, line)
	}

	legend := NewSemanticLegend([]string{"class", "method", "variable", "unstyled"}, []string{"declaration", "static"})
	rng := rand.New(rand.NewPCG(5, 1794))
	var tokens []SemanticToken
	for line := range text.LineCount() {
		length := len(text.Line(line))
		for at := 0; at < length; {
			at += rng.IntN(6)
			n := 1 + rng.IntN(8)
			if at < length {
				tokens = append(tokens, SemanticToken{Line: uint32(line), StartChar: uint32(at), Length: uint32(n),
					Type: uint32(rng.IntN(4)), Modifiers: uint32(rng.IntN(4))})
			}
			at += n
		}
	}
	if !h.SetSemantic(text, legend, tokens) {
		t.Fatal("SetSemantic rejected the current text")
	}
	for line := range text.LineCount() {
		content := text.Line(line)
		length := len(content)
		want := expand(lexical[line], length)
		for _, tk := range tokens {
			name, ok := legend.Name(tk.Type, tk.Modifiers)
			if int(tk.Line) != line || !ok {
				continue
			}
			start, ok := byteOffset(content, int(tk.StartChar))
			if !ok || start >= length {
				continue
			}
			end, _ := byteOffset(content, int(tk.StartChar+tk.Length))
			for b := start; b < end; b++ {
				want[b] = name
			}
		}
		got := h.Line(nil, line)
		if !slices.Equal(expand(got, length), want) {
			t.Fatalf("line %d: tokens %v, want per byte %v", line, got, want)
		}
		for i := 1; i < len(got); i++ {
			if got[i].Start <= got[i-1].Start || got[i].Name == got[i-1].Name {
				t.Fatalf("line %d: tokens %v are not merged", line, got)
			}
		}
	}

	// An answer for an older text is dropped.
	at := text.LineStart(3)
	next := text.Insert(at, []byte("\n"))
	h.Edit(next, at, at, at+1)
	if h.SetSemantic(text, legend, tokens) {
		t.Fatal("SetSemantic accepted tokens of an older text")
	}
	h.ClearSemantic()
	if got := h.Line(nil, 0); !slices.Equal(got, lexical[0]) {
		t.Fatalf("line 0 after ClearSemantic: tokens %v, want %v", got, lexical[0])
	}
}

// byteOffset returns the byte offset of UTF-16 code unit unit of line, rounded up to the end of
// a character, and whether line is that long; short of it, len(line).
func byteOffset(line string, unit int) (int, bool) {
	units := 0
	for offset, r := range line {
		if units >= unit {
			return offset, true
		}
		units++
		if r >= 0x10000 {
			units++
		}
	}
	return len(line), units >= unit
}

// expand returns the Name of each byte of a line length bytes long.
func expand(tokens []Token, length int) []Name {
	out := make([]Name, length)
	for i, t := range tokens {
		end := length
		if i+1 < len(tokens) {
			end = int(tokens[i+1].Start)
		}
		for b := int(t.Start); b < end; b++ {
			out[b] = t.Name
		}
	}
	return out
}

func TestHighlighterLineDoesNotAllocate(t *testing.T) {
	s := testSyntax(t, "java")
	text := rope.FromString(readSample(t, "Sample.java"))
	h := testHighlighter(s, text, 0, nil)
	drain(t, h)
	h.Prepare(0, 60)
	dst := make([]Token, 0, 256)
	paint := func() {
		h.Prepare(0, 60)
		for line := 0; line <= 60; line++ {
			dst = h.Line(dst[:0], line)
		}
	}
	if allocs := testing.AllocsPerRun(50, paint); allocs != 0 {
		t.Fatalf("painting cached lines allocates %v times", allocs)
	}
	legend := NewSemanticLegend([]string{"method"}, []string{"declaration"})
	tokens := []SemanticToken{{Line: 10, StartChar: 4, Length: 6, Modifiers: 1}, {Line: 20, StartChar: 0, Length: 3}}
	if !h.SetSemantic(text, legend, tokens) {
		t.Fatal("SetSemantic rejected the current text")
	}
	if allocs := testing.AllocsPerRun(50, paint); allocs != 0 {
		t.Fatalf("painting cached lines with semantic tokens allocates %v times", allocs)
	}
}

func BenchmarkHighlighterLine(b *testing.B) {
	s := testSyntax(b, "java")
	text := rope.FromString(readSample(b, "Sample.java"))
	h := testHighlighter(s, text, 0, nil)
	drain(b, h)
	h.Prepare(0, 60)
	dst := make([]Token, 0, 256)
	b.ReportAllocs()
	for i := 0; b.Loop(); i++ {
		dst = h.Line(dst[:0], i%61)
	}
}

func BenchmarkHighlighterTypeLetter(b *testing.B) {
	s := testSyntax(b, "java")
	text := rope.FromString(strings.Repeat(readSample(b, "Sample.java"), 40))
	h := testHighlighter(s, text, 0, nil)
	drain(b, h)
	h.Prepare(1000, 1060)
	at := text.LineStart(1030)
	b.ReportAllocs()
	for b.Loop() {
		next := text.Insert(at, []byte("x"))
		h.Edit(next, at, at, at+1)
		drain(b, h)
		h.Edit(text, at, at+1, at)
		drain(b, h)
	}
}

// BenchmarkHighlighterKeystroke measures what typing costs before the next frame: the edited
// line tokenized at once, on a line far from its checkpoint, with no background work.
func BenchmarkHighlighterKeystroke(b *testing.B) {
	s := testSyntax(b, "java")
	text := rope.FromString(strings.Repeat(readSample(b, "Sample.java"), 40))
	h := testHighlighter(s, text, 0, nil)
	drain(b, h)
	line := 1024 + segmentLines - 2
	h.Prepare(line-30, line+30)
	at := text.LineStart(line) + 8
	b.ReportAllocs()
	for i := 0; b.Loop(); i++ {
		next := text.Insert(at, []byte("x"))
		h.Edit(next, at, at, at+1)
		text, at = next, at+1
		if i%64 == 63 {
			// Keep the line short and the checkpoints settled, as between words.
			b.StopTimer()
			next := text.Delete(at-64, at)
			h.Edit(next, at-64, at, at-64)
			text, at = next, at-64
			drain(b, h)
			b.StartTimer()
		}
	}
}
