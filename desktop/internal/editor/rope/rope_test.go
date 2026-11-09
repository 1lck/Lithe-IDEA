package rope

import (
	"fmt"
	"math/rand/v2"
	"strings"
	"testing"
	"unicode/utf8"
)

// check fails t when the tree of r breaks an invariant: leaves at one depth, counts that add
// up, no empty or oversized leaf, no leaf split inside a UTF-8 sequence of valid text.
func check(t *testing.T, r Rope) {
	t.Helper()
	if r.root == nil {
		return
	}
	var walk func(n *node, depth int)
	leafDepth := -1
	walk = func(n *node, depth int) {
		if n.children == nil {
			if leafDepth < 0 {
				leafDepth = depth
			}
			if depth != leafDepth {
				t.Fatalf("leaf at depth %d, want %d", depth, leafDepth)
			}
			if n.length != len(n.text) || n.newlines != strings.Count(n.text, "\n") {
				t.Fatalf("leaf counts %d/%d do not match its text", n.length, n.newlines)
			}
			if n.length == 0 || n.length > maxLeaf {
				t.Fatalf("leaf of %d bytes", n.length)
			}
			return
		}
		length, lines := 0, 0
		for _, child := range n.children {
			if child.height != n.height-1 {
				t.Fatalf("child height %d under %d", child.height, n.height)
			}
			walk(child, depth+1)
			length += child.length
			lines += child.newlines
		}
		if length != n.length || lines != n.newlines || len(n.children) > maxChildren {
			t.Fatalf("node counts %d/%d, children add up to %d/%d over %d", n.length, n.newlines, length, lines, len(n.children))
		}
	}
	walk(r.root, 0)
}

// same fails t when r does not hold want, line for line.
func same(t *testing.T, r Rope, want string) {
	t.Helper()
	check(t, r)
	if got := r.String(); got != want {
		t.Fatalf("rope holds %q..., want %q...", trim(got), trim(want))
	}
	lines := strings.Split(want, "\n")
	if r.LineCount() != len(lines) {
		t.Fatalf("LineCount %d, want %d", r.LineCount(), len(lines))
	}
	offset := 0
	for i, line := range lines {
		if got := r.LineStart(i); got != offset {
			t.Fatalf("LineStart(%d) = %d, want %d", i, got, offset)
		}
		if got := r.LineEnd(i); got != offset+len(line) {
			t.Fatalf("LineEnd(%d) = %d, want %d", i, got, offset+len(line))
		}
		if got := r.Line(i); got != line {
			t.Fatalf("Line(%d) = %q, want %q", i, trim(got), trim(line))
		}
		if got := r.LineOf(offset); got != i {
			t.Fatalf("LineOf(%d) = %d, want %d", offset, got, i)
		}
		if got := r.LineOf(offset + len(line)); got != i {
			t.Fatalf("LineOf(end of %d) = %d", i, got)
		}
		offset += len(line) + 1
	}
}

func trim(s string) string {
	if len(s) > 40 {
		return s[:40]
	}
	return s
}

func TestEmptyRopeHasOneEmptyLine(t *testing.T) {
	var r Rope
	if r.Len() != 0 || r.LineCount() != 1 || r.Line(0) != "" || r.LineStart(3) != 0 || r.LineOf(5) != 0 {
		t.Fatalf("empty rope: len %d, lines %d", r.Len(), r.LineCount())
	}
	same(t, r.Insert(0, []byte("a\nb")), "a\nb")
}

// A line that lies inside one leaf is a substring of the leaf: Line returns it without an
// allocation, and LineCopied says so. Only a line that crosses leaves is joined into a new string.
func TestLineSharesTheLeafItLiesIn(t *testing.T) {
	var b strings.Builder
	for i := range 2000 {
		fmt.Fprintf(&b, "line %04d of the text\n", i)
	}
	text := b.String()
	r := New([]byte(text))
	check(t, r)
	if r.root.children == nil {
		t.Fatal("the text fits in one leaf, so no line could straddle one")
	}
	lines := strings.Split(text, "\n")
	if r.LineCount() != len(lines) {
		t.Fatalf("LineCount %d, want %d", r.LineCount(), len(lines))
	}
	for i, want := range lines {
		if got := r.Line(i); got != want {
			t.Fatalf("Line(%d) = %q, want %q", i, got, want)
		}
		// Every line is far shorter than a leaf, and a split falls after a line break, so no
		// line of a freshly built rope crosses leaves.
		got, copied := r.LineCopied(i)
		if got != want || copied {
			t.Fatalf("LineCopied(%d) = %q, %v, want %q, false", i, got, copied, want)
		}
	}
	if allocs := testing.AllocsPerRun(100, func() { _ = r.Line(5) }); allocs != 0 {
		t.Fatalf("Line of a line inside one leaf allocates %v times", allocs)
	}

	// One line longer than a leaf must be joined from several.
	long := strings.Repeat("y", 3*maxLeaf)
	r2 := New([]byte(long))
	if got, copied := r2.LineCopied(0); got != long || !copied {
		t.Fatalf("LineCopied of a line across leaves = %d bytes, %v, want %d bytes, true", len(got), copied, len(long))
	}
	if got := r2.Line(0); got != long {
		t.Fatalf("Line of a line across leaves = %d bytes, want %d", len(got), len(long))
	}

	// A line that does not exist is empty and was not copied.
	for _, line := range []int{-1, r.LineCount(), r.LineCount() + 10} {
		if got, copied := r.LineCopied(line); got != "" || copied {
			t.Fatalf("LineCopied(%d) = %q, %v, want \"\", false", line, trim(got), copied)
		}
		if got := r.Line(line); got != "" {
			t.Fatalf("Line(%d) = %q, want \"\"", line, trim(got))
		}
	}
	var empty Rope
	if got := empty.Line(0); got != "" {
		t.Fatalf("Line(0) of an empty rope = %q", got)
	}
	if got, copied := empty.LineCopied(0); got != "" || copied {
		t.Fatalf("LineCopied(0) of an empty rope = %q, %v", got, copied)
	}
}

// Substring is the bytes of a range, part of the leaf when the range lies inside one and joined
// from the leaves otherwise; it clamps the range, and an empty one is "" and was not copied.
func TestSubstringSharesTheLeafItLiesIn(t *testing.T) {
	var b strings.Builder
	for i := range 4000 {
		fmt.Fprintf(&b, "%d 中文\té ", i)
	}
	text := b.String()
	r := New([]byte(text))
	check(t, r)
	if r.root.children == nil {
		t.Fatal("the text fits in one leaf, so no range could cross leaves")
	}
	for _, c := range [][2]int{
		{0, 0}, {0, 1}, {5, 900}, {0, maxLeaf + 3}, {maxLeaf - 7, maxLeaf + 7},
		{len(text) / 2, len(text)/2 + 3*maxLeaf}, {len(text) - 9, len(text)}, {0, len(text)},
	} {
		start, end := c[0], c[1]
		got, copied := r.Substring(start, end)
		if got != text[start:end] {
			t.Fatalf("Substring(%d, %d) = %d bytes, want %d", start, end, len(got), end-start)
		}
		joined := false
		var leaves int
		r.Chunks(start, end, func(string) bool { leaves++; return true })
		if leaves > 1 {
			joined = true
		}
		if copied != joined {
			t.Fatalf("Substring(%d, %d) copied = %v, want %v, as it lies in %d leaves", start, end, copied, joined, leaves)
		}
	}
	if allocs := testing.AllocsPerRun(100, func() { _, _ = r.Substring(10, 50) }); allocs != 0 {
		t.Fatalf("Substring of a range inside one leaf allocates %v times", allocs)
	}
	for _, c := range [][2]int{{-5, 3}, {len(text) - 2, len(text) + 10}, {20, 10}, {len(text) + 1, len(text) + 5}} {
		start, end := c[0], c[1]
		want := ""
		if s, e := max(start, 0), min(end, len(text)); s < e {
			want = text[s:e]
		}
		if got, _ := r.Substring(start, end); got != want {
			t.Fatalf("Substring(%d, %d) = %q, want %q", start, end, trim(got), trim(want))
		}
	}
	var empty Rope
	if got, copied := empty.Substring(0, 5); got != "" || copied {
		t.Fatalf("Substring of an empty rope = %q, %v", got, copied)
	}
}

// FromString keeps the string it is given, which cannot change, instead of copying it.
func TestFromStringSharesItsText(t *testing.T) {
	s := strings.Repeat("share me\n", 1000)
	r := FromString(s)
	check(t, r)
	if got := r.String(); got != s {
		t.Fatalf("String = %q..., want %q...", trim(got), trim(s))
	}
	if !r.Equal(New([]byte(s))) {
		t.Fatal("a rope from a string is not Equal to one from the same bytes")
	}
	// A rope of one leaf is that leaf's memory, so reading it back allocates nothing.
	small := FromString("one leaf")
	if allocs := testing.AllocsPerRun(100, func() { _ = small.String() }); allocs != 0 {
		t.Fatalf("String of a one-leaf rope allocates %v times", allocs)
	}
}

func TestNewBuildsBalancedTrees(t *testing.T) {
	for _, size := range []int{1, maxLeaf, maxLeaf + 1, 2 * maxLeaf, 2*maxLeaf + 1, 100_000, 1 << 20} {
		var b strings.Builder
		for i := 0; b.Len() < size; i++ {
			b.WriteString("line ")
			b.WriteString(strings.Repeat("x", i%97))
			b.WriteByte('\n')
		}
		text := b.String()[:size]
		same(t, FromString(text), text)
	}
}

func TestLeavesDoNotSplitCharacters(t *testing.T) {
	text := strings.Repeat("汉字测试", 4000)
	r := FromString(text)
	check(t, r)
	r.Chunks(0, r.Len(), func(chunk string) bool {
		if !utf8.ValidString(chunk) {
			t.Fatalf("leaf of %d bytes splits a character", len(chunk))
		}
		return true
	})
}

func TestReplaceMatchesAStringModel(t *testing.T) {
	random := rand.New(rand.NewPCG(1, 2))
	alphabet := []string{"a", "b", "\n", "汉", "xyz", "\n\n", strings.Repeat("q", 300)}
	model := strings.Repeat("hello world\n", 2000)
	r := FromString(model)
	versions := []struct {
		rope Rope
		text string
	}{{r, model}}
	for step := range 3000 {
		start := random.IntN(len(model) + 1)
		end := start
		if random.IntN(3) == 0 {
			end = min(len(model), start+random.IntN(5000))
		}
		var insert strings.Builder
		for range random.IntN(4) {
			insert.WriteString(alphabet[random.IntN(len(alphabet))])
		}
		if random.IntN(50) == 0 {
			insert.WriteString(strings.Repeat("big\n", 3000))
		}
		r = r.Replace(start, end, []byte(insert.String()))
		model = model[:start] + insert.String() + model[end:]
		if step%100 == 0 {
			same(t, r, model)
			versions = append(versions, struct {
				rope Rope
				text string
			}{r, model})
		}
	}
	same(t, r, model)
	// Every earlier version is unchanged by the edits made after it.
	for _, v := range versions {
		if v.rope.String() != v.text {
			t.Fatal("an edit changed an earlier version")
		}
	}
}

// Equal agrees with comparing the bytes, whether the ropes share their unedited nodes, are built
// separately with other leaf boundaries, or differ in one byte with the same length and lines.
func TestEqualMatchesComparingTheBytes(t *testing.T) {
	random := rand.New(rand.NewPCG(3, 4))
	model := strings.Repeat("hello world\n", 3000)
	r := FromString(model)
	type version struct {
		rope Rope
		text string
	}
	versions := []version{{r, model}, {FromString(model), model}}
	for step := range 400 {
		at := random.IntN(len(model) + 1)
		switch random.IntN(4) {
		case 0:
			// A byte typed and deleted again: equal text, a new path to the leaf.
			r = r.Insert(at, []byte{'k'}).Delete(at, at+1)
		case 1:
			if at < len(model) && model[at] != '\n' {
				r = r.Replace(at, at+1, []byte{'Z'})
				model = model[:at] + "Z" + model[at+1:]
			}
		case 2:
			insert := strings.Repeat("big\n", random.IntN(800))
			r = r.Insert(at, []byte(insert))
			model = model[:at] + insert + model[at:]
		default:
			end := min(len(model), at+random.IntN(3000))
			r = r.Delete(at, end)
			model = model[:at] + model[end:]
		}
		if step%20 == 0 {
			versions = append(versions, version{r, model}, version{FromString(model), model})
		}
	}
	versions = append(versions, version{r, model}, version{Rope{}, ""}, version{FromString(""), ""})
	for i, a := range versions {
		for j, b := range versions {
			if got, want := a.rope.Equal(b.rope), a.text == b.text; got != want {
				t.Fatalf("versions %d and %d: Equal = %v, want %v", i, j, got, want)
			}
		}
	}
}

func TestDeletingEverythingLeavesAnEmptyRope(t *testing.T) {
	r := FromString(strings.Repeat("abc\n", 5000))
	r = r.Delete(0, r.Len())
	same(t, r, "")
}

func TestReplaceClampsItsRange(t *testing.T) {
	r := FromString("hello")
	same(t, r.Replace(-5, 2, []byte("J")), "Jllo")
	same(t, r.Replace(3, 99, nil), "hel")
	same(t, r.Replace(4, 2, []byte("!")), "hell!o")
}

func TestChunksStopsWhenAsked(t *testing.T) {
	r := FromString(strings.Repeat("x", 10*maxLeaf))
	calls := 0
	r.Chunks(0, r.Len(), func(string) bool { calls++; return false })
	if calls != 1 {
		t.Fatalf("yield called %d times after returning false", calls)
	}
	if got := string(r.AppendRange(nil, maxLeaf-2, maxLeaf+3)); got != "xxxxx" {
		t.Fatalf("AppendRange across leaves = %q", got)
	}
}

func TestTypingKeepsTheTreeShallow(t *testing.T) {
	r := FromString(strings.Repeat("0123456789\n", 100_000))
	at := r.Len() / 2
	for i := range 20_000 {
		r = r.Insert(at+i, []byte{'k'})
	}
	check(t, r)
	if r.root.height > 5 {
		t.Fatalf("height %d after typing", r.root.height)
	}
}

func BenchmarkTypeInALargeDocument(b *testing.B) {
	r := FromString(strings.Repeat("0123456789 abcdefghij\n", 500_000))
	at := r.Len() / 2
	b.ResetTimer()
	for i := range b.N {
		r = r.Insert(at+i%1000, []byte{'k'})
	}
}

func BenchmarkLineStart(b *testing.B) {
	r := FromString(strings.Repeat("0123456789 abcdefghij\n", 500_000))
	b.ResetTimer()
	for i := range b.N {
		_ = r.LineStart(i % 500_000)
	}
}
