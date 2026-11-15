package syntax

import "github.com/1lck/Lithe-IDEA/desktop/internal/editor/textmate"

// segmentLines is how many lines apart the highlighter keeps tokenizer states. Lines between
// two checkpoints are a segment: a line's tokens are recomputed from the checkpoint before it,
// so a document keeps one state per segmentLines lines instead of one per line.
const segmentLines = 32

// checkpoints are the tokenizer states at the start of a few lines of a document, sorted by
// line, the first always at line 0 in the initial state.
//
// The states converge after an edit the way VS Code's do, a segment at a time: an edit marks
// its segment dirty, meaning its start state is right but the state its lines end in may not
// match the next checkpoint's any more. Tokenizing a dirty segment either ends in the next
// checkpoint's state, and every later checkpoint is right again, or replaces that state and
// marks the next segment dirty. A checkpoint's state is therefore right when no segment before
// it is dirty; after the first dirty segment, states are the most likely ones but unconfirmed.
type checkpoints struct {
	lines  []int32
	states []*textmate.StateStack
	dirty  []bool
	// firstDirty is the index of the first dirty segment, or len(lines) when none is.
	firstDirty int
}

// reset makes the checkpoints of a document nothing is known about: the initial state at line
// 0, its segment dirty and running to the end.
func (c *checkpoints) reset() {
	clear(c.states)
	c.lines = append(c.lines[:0], 0)
	c.states = append(c.states[:0], nil)
	c.dirty = append(c.dirty[:0], true)
	c.firstDirty = 0
}

// find returns the index of the last checkpoint at or before line.
func (c *checkpoints) find(line int) int {
	lo, hi := 0, len(c.lines)
	for hi-lo > 1 {
		mid := int(uint(lo+hi) >> 1)
		if int(c.lines[mid]) <= line {
			lo = mid
		} else {
			hi = mid
		}
	}
	return lo
}

// end is the line segment i ends before: the next checkpoint's line, or count, the number of
// lines of the document.
func (c *checkpoints) end(i, count int) int {
	if i+1 < len(c.lines) {
		return int(c.lines[i+1])
	}
	return count
}

// edit moves the checkpoints across an edit that replaced lines startLine to endLine and
// changed the number of lines by delta. Checkpoints on the lines that went are dropped, later
// ones move, and the segment of startLine becomes dirty.
func (c *checkpoints) edit(startLine, endLine, delta int) {
	s := c.find(startLine)
	lo, hi := s+1, s+1
	for hi < len(c.lines) && int(c.lines[hi]) <= endLine {
		hi++
	}
	if hi > lo {
		n := len(c.lines) - (hi - lo)
		c.lines = append(c.lines[:lo], c.lines[hi:]...)
		copy(c.states[lo:], c.states[hi:])
		clear(c.states[n:])
		c.states = c.states[:n]
		c.dirty = append(c.dirty[:lo], c.dirty[hi:]...)
		if c.firstDirty >= hi {
			c.firstDirty -= hi - lo
		}
	}
	if delta != 0 {
		for j := lo; j < len(c.lines); j++ {
			c.lines[j] += int32(delta)
		}
	}
	c.dirty[s] = true
	c.firstDirty = min(c.firstDirty, s)
}

// insert adds a checkpoint after segment i, at line, with state.
func (c *checkpoints) insert(i, line int, state *textmate.StateStack, dirty bool) {
	at := i + 1
	c.lines = append(c.lines, 0)
	copy(c.lines[at+1:], c.lines[at:])
	c.lines[at] = int32(line)
	c.states = append(c.states, nil)
	copy(c.states[at+1:], c.states[at:])
	c.states[at] = state
	c.dirty = append(c.dirty, false)
	copy(c.dirty[at+1:], c.dirty[at:])
	c.dirty[at] = dirty
	if c.firstDirty > i {
		c.firstDirty++
		if dirty {
			c.firstDirty = min(c.firstDirty, at)
		}
	}
}

// clean marks segment i no longer dirty.
func (c *checkpoints) clean(i int) {
	c.dirty[i] = false
	if c.firstDirty != i {
		return
	}
	next := i + 1
	for next < len(c.dirty) && !c.dirty[next] {
		next++
	}
	c.firstDirty = next
}
