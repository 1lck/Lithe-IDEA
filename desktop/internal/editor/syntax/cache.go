package syntax

import (
	"math"
	"slices"
)

// tokenCache keeps the tokens of the lines a view showed recently, so that painting a line
// again does not tokenize it again. Tokens of every line live in one arena of uint32 pairs,
// start byte and Name, and the entries that index it hold no pointers either, so the garbage
// collector never scans the cache however many lines it holds.
//
// The cache holds at most capacity lines. Lines in the pinned range, the ones on screen, stay;
// past capacity the least recently used other lines go, a quarter of the capacity at a time.
// The arena is compacted into a spare one once more than half of it is garbage, so after the
// first screens neither growing nor compacting allocates.
type tokenCache struct {
	entries  []cacheEntry
	arena    []uint32
	spare    []uint32
	live     int
	tick     uint32
	capacity int
	pinFirst int
	pinLast  int
	// ticks is scratch for eviction.
	ticks []uint32
}

// cacheEntry is one cached line: its tokens are arena[off:off+n], two values per token.
type cacheEntry struct {
	line int32
	off  uint32
	n    uint32
	used uint32
}

// defaultCacheLines is how many lines a highlighter keeps tokens for: dozens of screens.
const defaultCacheLines = 2048

func newTokenCache(capacity int) tokenCache {
	return tokenCache{capacity: max(capacity, 16), pinFirst: -1, pinLast: -1}
}

func (c *tokenCache) search(line int) (int, bool) {
	lo, hi := 0, len(c.entries)
	for lo < hi {
		mid := int(uint(lo+hi) >> 1)
		if int(c.entries[mid].line) < line {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo, lo < len(c.entries) && int(c.entries[lo].line) == line
}

func (c *tokenCache) touch(i int) {
	if c.tick == math.MaxUint32 {
		for j := range c.entries {
			c.entries[j].used = 0
		}
		c.tick = 0
	}
	c.tick++
	c.entries[i].used = c.tick
}

// get returns the tokens of line, valid until the cache next changes.
func (c *tokenCache) get(line int) ([]uint32, bool) {
	i, ok := c.search(line)
	if !ok {
		return nil, false
	}
	c.touch(i)
	e := c.entries[i]
	return c.arena[e.off : e.off+e.n], true
}

// has says whether line is cached, without marking it used.
func (c *tokenCache) has(line int) bool {
	_, ok := c.search(line)
	return ok
}

// put caches the tokens of line and reports whether they differ from those cached before.
func (c *tokenCache) put(line int, tokens []uint32) bool {
	i, ok := c.search(line)
	if ok {
		e := &c.entries[i]
		old := c.arena[e.off : e.off+e.n]
		if slices.Equal(old, tokens) {
			c.touch(i)
			return false
		}
		if len(tokens) <= len(old) {
			copy(old, tokens)
			c.live -= len(old) - len(tokens)
			e.n = uint32(len(tokens))
		} else {
			c.live += len(tokens) - len(old)
			e.off, e.n = uint32(len(c.arena)), uint32(len(tokens))
			c.arena = append(c.arena, tokens...)
		}
		c.touch(i)
		c.maybeCompact()
		return true
	}
	c.entries = slices.Insert(c.entries, i, cacheEntry{line: int32(line), off: uint32(len(c.arena)), n: uint32(len(tokens))})
	c.arena = append(c.arena, tokens...)
	c.live += len(tokens)
	c.touch(i)
	if len(c.entries) > c.capacity {
		c.evict()
	}
	c.maybeCompact()
	return true
}

// remove drops the lines from first to last.
func (c *tokenCache) remove(first, last int) {
	lo, _ := c.search(first)
	hi, _ := c.search(last + 1)
	for _, e := range c.entries[lo:hi] {
		c.live -= int(e.n)
	}
	c.entries = slices.Delete(c.entries, lo, hi)
}

// shift moves the lines after line by delta.
func (c *tokenCache) shift(after, delta int) {
	if delta == 0 {
		return
	}
	i, _ := c.search(after + 1)
	for ; i < len(c.entries); i++ {
		c.entries[i].line += int32(delta)
	}
}

func (c *tokenCache) clear() {
	c.entries = c.entries[:0]
	c.arena = c.arena[:0]
	c.live = 0
}

// pin keeps the lines from first to last from being evicted.
func (c *tokenCache) pin(first, last int) { c.pinFirst, c.pinLast = first, last }

func (c *tokenCache) pinned(line int32) bool {
	return int(line) >= c.pinFirst && int(line) <= c.pinLast
}

// evict drops the least recently used unpinned lines until the cache is at three quarters of
// its capacity.
func (c *tokenCache) evict() {
	excess := len(c.entries) - c.capacity*3/4
	c.ticks = c.ticks[:0]
	for _, e := range c.entries {
		if !c.pinned(e.line) {
			c.ticks = append(c.ticks, e.used)
		}
	}
	if excess <= 0 || len(c.ticks) == 0 {
		return
	}
	excess = min(excess, len(c.ticks))
	slices.Sort(c.ticks)
	threshold := c.ticks[excess-1]
	kept := c.entries[:0]
	for _, e := range c.entries {
		if excess > 0 && e.used <= threshold && !c.pinned(e.line) {
			excess--
			c.live -= int(e.n)
			continue
		}
		kept = append(kept, e)
	}
	c.entries = kept
}

// maybeCompact copies the live tokens into the spare arena once more than half of the arena
// is garbage, then swaps the two.
func (c *tokenCache) maybeCompact() {
	if len(c.arena) < 4096 || c.live*2 > len(c.arena) {
		return
	}
	next := c.spare[:0]
	for i := range c.entries {
		e := &c.entries[i]
		off := uint32(len(next))
		next = append(next, c.arena[e.off:e.off+e.n]...)
		e.off = off
	}
	c.spare = c.arena[:0]
	c.arena = next
}
