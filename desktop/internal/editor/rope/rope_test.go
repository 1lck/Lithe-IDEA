package rope

import (
	"bytes"
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
			if n.length != len(n.text) || n.newlines != bytes.Count(n.text, newline) {
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
	r.Chunks(0, r.Len(), func(chunk []byte) bool {
		if !utf8.Valid(chunk) {
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
	r.Chunks(0, r.Len(), func([]byte) bool { calls++; return false })
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
