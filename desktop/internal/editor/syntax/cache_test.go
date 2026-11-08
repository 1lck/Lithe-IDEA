package syntax

import (
	"math/rand/v2"
	"slices"
	"testing"
)

// checkCache checks the cache's own invariants: entries sorted by line without repeats, and
// live counting exactly the values the entries hold.
func checkCache(t *testing.T, c *tokenCache) {
	t.Helper()
	live := 0
	for i, e := range c.entries {
		if i > 0 && c.entries[i-1].line >= e.line {
			t.Fatalf("entries out of order at %d: %v", i, c.entries)
		}
		if int(e.off+e.n) > len(c.arena) {
			t.Fatalf("entry %v runs past the arena of %d", e, len(c.arena))
		}
		live += int(e.n)
	}
	if live != c.live {
		t.Fatalf("live is %d, entries hold %d", c.live, live)
	}
}

func TestTokenCachePutReportsChanges(t *testing.T) {
	c := newTokenCache(16)
	if !c.put(3, []uint32{0, 1}) {
		t.Fatal("first put reports no change")
	}
	if c.put(3, []uint32{0, 1}) {
		t.Fatal("same tokens report a change")
	}
	if !c.put(3, []uint32{0, 2, 4, 1}) {
		t.Fatal("longer tokens report no change")
	}
	if !c.put(3, []uint32{0, 5}) {
		t.Fatal("shorter tokens report no change")
	}
	if got, ok := c.get(3); !ok || !slices.Equal(got, []uint32{0, 5}) {
		t.Fatalf("get(3) = %v, %v", got, ok)
	}
	if _, ok := c.get(4); ok {
		t.Fatal("get of an uncached line succeeds")
	}
	checkCache(t, &c)
}

func TestTokenCacheEvictsLeastRecentlyUsedUnpinned(t *testing.T) {
	c := newTokenCache(16)
	c.pin(0, 3)
	for line := range 16 {
		c.put(line, []uint32{0, uint32(line)})
	}
	// Lines 4 to 8 are now the least recently used ones that are not pinned.
	for line := 9; line < 16; line++ {
		c.get(line)
	}
	c.put(16, []uint32{0, 16})
	if len(c.entries) != 12 {
		t.Fatalf("%d lines kept, want 12", len(c.entries))
	}
	for line := range 17 {
		want := line < 4 || line > 8
		if c.has(line) != want {
			t.Fatalf("line %d cached %v, want %v", line, c.has(line), want)
		}
	}
	checkCache(t, &c)

	// Pinned lines stay even when they are more than the capacity.
	c.pin(0, 100)
	for line := range 40 {
		c.put(line, []uint32{0, 1})
	}
	for line := range 40 {
		if !c.has(line) {
			t.Fatalf("pinned line %d evicted", line)
		}
	}
	checkCache(t, &c)
}

func TestTokenCacheRemoveAndShift(t *testing.T) {
	c := newTokenCache(16)
	for line := range 10 {
		c.put(line, []uint32{0, uint32(line)})
	}
	c.remove(3, 5)
	c.shift(5, 2)
	for line, want := range map[int]int{0: 0, 2: 2, 8: 6, 11: 9} {
		if got, ok := c.get(line); !ok || got[1] != uint32(want) {
			t.Fatalf("line %d: tokens %v, %v, want those of old line %d", line, got, ok, want)
		}
	}
	for _, line := range []int{3, 4, 5, 6, 7} {
		if c.has(line) {
			t.Fatalf("line %d still cached", line)
		}
	}
	checkCache(t, &c)
}

func TestTokenCacheAgainstModel(t *testing.T) {
	c := newTokenCache(32)
	model := map[int][]uint32{}
	rng := rand.New(rand.NewPCG(32, 1794))
	for range 20000 {
		switch op := rng.IntN(20); {
		case op < 12:
			line := rng.IntN(100)
			tokens := make([]uint32, 2*(1+rng.IntN(200)))
			for i := range tokens {
				tokens[i] = rng.Uint32()
			}
			c.put(line, tokens)
			model[line] = tokens
			// Once past its first size, the arena is compacted whenever half of it is garbage.
			if len(c.arena) >= 4096 && 2*c.live <= len(c.arena) {
				t.Fatalf("arena of %d values for %d live ones", len(c.arena), c.live)
			}
		case op < 16:
			line := rng.IntN(100)
			got, ok := c.get(line)
			if want, cached := model[line]; ok && (!cached || !slices.Equal(got, want)) {
				t.Fatalf("line %d: tokens %v, want %v", line, got, want)
			}
		case op < 17:
			first := rng.IntN(100)
			last := first + rng.IntN(5)
			c.remove(first, last)
			for line := first; line <= last; line++ {
				delete(model, line)
			}
		case op < 18:
			after, delta := rng.IntN(100), rng.IntN(7)-3
			// A shift follows a remove of the lines it moves over, as an edit does.
			c.remove(after+1+min(delta, 0), after)
			for line := after + 1 + min(delta, 0); line <= after; line++ {
				delete(model, line)
			}
			c.shift(after, delta)
			moved := map[int][]uint32{}
			for line, tokens := range model {
				if line > after {
					line += delta
				}
				moved[line] = tokens
			}
			model = moved
		case op < 19:
			first := rng.IntN(100)
			c.pin(first, first+rng.IntN(20))
		default:
			c.clear()
			clear(model)
		}
		checkCache(t, &c)
		for line := range model {
			if !c.has(line) {
				if c.pinned(int32(line)) {
					t.Fatalf("pinned line %d evicted", line)
				}
				delete(model, line)
			}
		}
		if len(c.entries) != len(model) {
			t.Fatalf("cache holds %d lines, model %d", len(c.entries), len(model))
		}
	}
}

func TestCheckpointsEdit(t *testing.T) {
	var c checkpoints
	c.reset()
	for _, line := range []int{32, 64, 96} {
		c.insert(len(c.lines)-1, line, nil, false)
	}
	c.clean(0)
	if !slices.Equal(c.lines, []int32{0, 32, 64, 96}) || c.firstDirty != 4 {
		t.Fatalf("lines %v, first dirty %d", c.lines, c.firstDirty)
	}
	if got := c.find(63); got != 1 {
		t.Fatalf("find(63) = %d, want 1", got)
	}
	if got := c.find(64); got != 2 {
		t.Fatalf("find(64) = %d, want 2", got)
	}
	if got := c.end(3, 120); got != 120 {
		t.Fatalf("end of the last segment = %d, want 120", got)
	}

	// Lines 40 to 70 become 20 lines: the checkpoint at 64 goes and the one at 96 moves up.
	c.edit(40, 70, -10)
	if !slices.Equal(c.lines, []int32{0, 32, 86}) || !slices.Equal(c.dirty, []bool{false, true, false}) || c.firstDirty != 1 {
		t.Fatalf("after edit: lines %v, dirty %v, first dirty %d", c.lines, c.dirty, c.firstDirty)
	}
	// Splitting the dirty segment keeps the first dirty one in order.
	c.insert(1, 50, nil, true)
	c.clean(1)
	if !slices.Equal(c.lines, []int32{0, 32, 50, 86}) || c.firstDirty != 2 {
		t.Fatalf("after split: lines %v, first dirty %d", c.lines, c.firstDirty)
	}
	// An edit on a checkpoint's own line keeps it and dirties its segment.
	c.edit(86, 86, 3)
	if !slices.Equal(c.lines, []int32{0, 32, 50, 86}) || !c.dirty[3] || c.firstDirty != 2 {
		t.Fatalf("after edit at 86: lines %v, dirty %v, first dirty %d", c.lines, c.dirty, c.firstDirty)
	}
	c.clean(2)
	if c.firstDirty != 3 {
		t.Fatalf("after clean: first dirty %d, want 3", c.firstDirty)
	}
	c.clean(3)
	if c.firstDirty != 4 {
		t.Fatalf("all clean: first dirty %d, want 4", c.firstDirty)
	}
	// Joining lines across checkpoints drops them all.
	c.edit(10, 90, -80)
	if !slices.Equal(c.lines, []int32{0}) || c.firstDirty != 0 {
		t.Fatalf("after join: lines %v, first dirty %d", c.lines, c.firstDirty)
	}
}
