// Package rope is the text of an open document: a persistent B-tree of byte chunks in which
// every node knows how many bytes and line breaks it holds.
//
// A Rope never changes. Replace returns a new one that shares every node the edit did not
// touch, so an edit costs O(log n) in the size of the text, and keeping the text as it was
// before an edit, for undo, a background tokenizer or a diff, costs nothing but the pointer.
// Finding where a line starts, or which line an offset is on, walks one path from the root.
//
// Offsets are byte offsets. A line ends at "\n", which belongs to the line it ends; a
// document that uses "\r\n" is normalized before it reaches the rope (see package editor).
package rope

import (
	"bytes"
	"unicode/utf8"
)

// The shape of the tree. A leaf holds at most maxLeaf bytes and an inner node at most
// maxChildren children. A leaf below minLeaf bytes, or a node below minChildren children, is
// merged with its neighbour when an edit joins them. Leaves of about a kilobyte keep a
// keystroke's copy small and the tree shallow: a 100 MB document is five levels deep.
const (
	maxLeaf     = 2048
	minLeaf     = 512
	maxChildren = 16
	minChildren = 4
)

// node is a leaf, which holds text, or an inner node, which holds children of one height less.
// A node is never changed once it is part of a Rope.
type node struct {
	// height is 0 at a leaf; every leaf of a tree is at the same depth.
	height int
	// length is the number of bytes below the node.
	length int
	// newlines is the number of "\n" bytes below the node.
	newlines int
	// children are an inner node's subtrees, in order; nil at a leaf.
	children []*node
	// text is a leaf's bytes, never appended to: a leaf made from part of another one
	// shares its array with a capacity that ends where the part does.
	text []byte
}

// Rope is an immutable text. The zero Rope is empty.
type Rope struct {
	root *node
}

// New returns a rope holding a copy of text.
func New(text []byte) Rope {
	return Rope{root: build(text)}
}

// FromString returns a rope holding text.
func FromString(text string) Rope {
	return New([]byte(text))
}

// Len returns the number of bytes in r.
func (r Rope) Len() int {
	if r.root == nil {
		return 0
	}
	return r.root.length
}

// LineCount returns the number of lines in r: one more than its line breaks, so an empty rope
// has one empty line and a text ending in "\n" has an empty last line.
func (r Rope) LineCount() int {
	if r.root == nil {
		return 1
	}
	return r.root.newlines + 1
}

// Same reports whether r and other are the same version of a text: one was made from the other
// by no edit. Two ropes with equal text made separately are not the same.
func (r Rope) Same(other Rope) bool {
	return r.root == other.root
}

// LineStart returns the offset at which line (counted from 0) begins. A line past the last one
// begins at Len.
func (r Rope) LineStart(line int) int {
	switch {
	case line <= 0 || r.root == nil:
		return 0
	case line > r.root.newlines:
		return r.root.length
	}
	return newlineOffset(r.root, line) + 1
}

// LineEnd returns the offset of the "\n" that ends line, or Len for the last line.
func (r Rope) LineEnd(line int) int {
	if r.root == nil || line >= r.root.newlines {
		return r.Len()
	}
	if line < 0 {
		line = 0
	}
	return newlineOffset(r.root, line+1)
}

// LineOf returns the line that offset is on. The offset of a "\n" is on the line the break ends;
// an offset past the end is on the last line.
func (r Rope) LineOf(offset int) int {
	if r.root == nil || offset <= 0 {
		return 0
	}
	if offset >= r.root.length {
		return r.root.newlines
	}
	line := 0
	n := r.root
	for n.children != nil {
		for _, child := range n.children {
			if offset < child.length {
				n = child
				break
			}
			offset -= child.length
			line += child.newlines
		}
	}
	return line + bytes.Count(n.text[:offset], newline)
}

// newline is the byte that ends a line, as a slice for bytes.Count.
var newline = []byte{'\n'}

// newlineOffset returns the offset of the k-th "\n" below n, counted from 1; n holds at least k.
func newlineOffset(n *node, k int) int {
	offset := 0
	for n.children != nil {
		for _, child := range n.children {
			if k <= child.newlines {
				n = child
				break
			}
			k -= child.newlines
			offset += child.length
		}
	}
	at := -1
	for ; k > 0; k-- {
		at += 1 + bytes.IndexByte(n.text[at+1:], '\n')
	}
	return offset + at
}

// AppendRange appends the bytes from start to end of r to dst. The range is clamped to r.
func (r Rope) AppendRange(dst []byte, start, end int) []byte {
	r.Chunks(start, end, func(chunk []byte) bool {
		dst = append(dst, chunk...)
		return true
	})
	return dst
}

// AppendLine appends line, without the "\n" that ends it, to dst.
func (r Rope) AppendLine(dst []byte, line int) []byte {
	if line < 0 || line >= r.LineCount() {
		return dst
	}
	return r.AppendRange(dst, r.LineStart(line), r.LineEnd(line))
}

// Line returns line, without the "\n" that ends it.
func (r Rope) Line(line int) string {
	return string(r.AppendLine(nil, line))
}

// Bytes returns a copy of all of r.
func (r Rope) Bytes() []byte {
	return r.AppendRange(make([]byte, 0, r.Len()), 0, r.Len())
}

// String returns all of r.
func (r Rope) String() string {
	return string(r.Bytes())
}

// ByteAt returns the byte at offset, which must be within r.
func (r Rope) ByteAt(offset int) byte {
	n := r.root
	for n.children != nil {
		for _, child := range n.children {
			if offset < child.length {
				n = child
				break
			}
			offset -= child.length
		}
	}
	return n.text[offset]
}

// Chunks calls yield with the bytes from start to end of r, a leaf's worth at a time and in
// order, until yield returns false. The range is clamped to r. A chunk is r's own memory and
// must not be changed or kept past the next edit's interest in it; it stays valid as long as
// r does.
func (r Rope) Chunks(start, end int, yield func(chunk []byte) bool) {
	start, end = max(start, 0), min(end, r.Len())
	if start >= end {
		return
	}
	chunks(r.root, start, end, yield)
}

// chunks walks the leaves of n that overlap start to end, offsets relative to n.
func chunks(n *node, start, end int, yield func([]byte) bool) bool {
	if n.children == nil {
		return yield(n.text[max(start, 0):min(end, n.length)])
	}
	offset := 0
	for _, child := range n.children {
		next := offset + child.length
		if next > start {
			if !chunks(child, start-offset, end-offset, yield) {
				return false
			}
		}
		offset = next
		if offset >= end {
			break
		}
	}
	return true
}

// Replace returns r with the bytes from start to end replaced by text; r is unchanged. start and
// end are clamped to r, and end to no less than start.
func (r Rope) Replace(start, end int, text []byte) Rope {
	start = min(max(start, 0), r.Len())
	end = min(max(end, start), r.Len())
	if start == end && len(text) == 0 {
		return r
	}
	if r.root == nil {
		return New(text)
	}
	// Most edits are a keystroke inside one leaf: copy that leaf and the path above it.
	if root, ok := replaceInLeaf(r.root, start, end, text); ok {
		return Rope{root: root}
	}
	left := slice(r.root, 0, start)
	right := slice(r.root, end, r.root.length)
	return Rope{root: concat(concat(left, build(text)), right)}
}

// Insert returns r with text inserted at offset.
func (r Rope) Insert(offset int, text []byte) Rope {
	return r.Replace(offset, offset, text)
}

// Delete returns r without the bytes from start to end.
func (r Rope) Delete(start, end int) Rope {
	return r.Replace(start, end, nil)
}

// replaceInLeaf replaces start to end below n with text when the range is inside one leaf and
// the leaf stays between minLeaf and maxLeaf bytes (or is the whole tree). It reports false,
// changing nothing, otherwise.
func replaceInLeaf(n *node, start, end int, text []byte) (*node, bool) {
	if n.children == nil {
		size := n.length - (end - start) + len(text)
		if size == 0 || size > maxLeaf {
			return nil, false
		}
		b := make([]byte, 0, size)
		b = append(b, n.text[:start]...)
		b = append(b, text...)
		b = append(b, n.text[end:]...)
		return newLeaf(b), true
	}
	offset := 0
	for i, child := range n.children {
		next := offset + child.length
		if start >= offset && end <= next {
			if child.children == nil && n.length-child.length > 0 {
				// A leaf that shrinks below minLeaf is joined with a neighbour instead.
				if size := child.length - (end - start) + len(text); size < minLeaf {
					return nil, false
				}
			}
			replaced, ok := replaceInLeaf(child, start-offset, end-offset, text)
			if !ok {
				return nil, false
			}
			children := make([]*node, len(n.children))
			copy(children, n.children)
			children[i] = replaced
			return fromNodes(children), true
		}
		if next > start {
			break
		}
		offset = next
	}
	return nil, false
}

// slice returns the part of n from start to end, offsets relative to n, or nil when it is
// empty. It shares every subtree that lies wholly inside the range.
func slice(n *node, start, end int) *node {
	if start <= 0 && end >= n.length {
		return n
	}
	if start >= end {
		return nil
	}
	if n.children == nil {
		start, end = max(start, 0), min(end, n.length)
		return newLeaf(n.text[start:end:end])
	}
	var out *node
	offset := 0
	for _, child := range n.children {
		next := offset + child.length
		if next > start && offset < end {
			out = concat(out, slice(child, start-offset, end-offset))
		}
		offset = next
		if offset >= end {
			break
		}
	}
	return out
}

// concat joins a and b, either of which may be nil, into one balanced tree. It is xi-editor's
// rope concatenation (Apache-2.0): the lower tree is joined to the edge of the taller one at
// its own height, and the nodes the join leaves too full are split.
func concat(a, b *node) *node {
	switch {
	case a == nil:
		return b
	case b == nil:
		return a
	}
	h1, h2 := a.height, b.height
	switch {
	case h1 < h2:
		if h1 == h2-1 && a.ok() {
			return mergeNodes([]*node{a}, b.children)
		}
		joined := concat(a, b.children[0])
		if joined.height == h2-1 {
			return mergeNodes([]*node{joined}, b.children[1:])
		}
		return mergeNodes(joined.children, b.children[1:])
	case h1 == h2:
		if a.ok() && b.ok() {
			return fromNodes([]*node{a, b})
		}
		if h1 == 0 {
			return mergeLeaves(a, b)
		}
		return mergeNodes(a.children, b.children)
	default:
		last := len(a.children) - 1
		if h2 == h1-1 && b.ok() {
			return mergeNodes(a.children, []*node{b})
		}
		joined := concat(a.children[last], b)
		if joined.height == h1-1 {
			return mergeNodes(a.children[:last], []*node{joined})
		}
		return mergeNodes(a.children[:last], joined.children)
	}
}

// ok reports whether n is big enough to be a child as it is.
func (n *node) ok() bool {
	if n.children == nil {
		return n.length >= minLeaf
	}
	return len(n.children) >= minChildren
}

// mergeNodes returns one node over first and then second, all of one height, or two nodes
// under a new one when they are more than a node holds.
func mergeNodes(first, second []*node) *node {
	total := len(first) + len(second)
	all := make([]*node, 0, total)
	all = append(append(all, first...), second...)
	if total <= maxChildren {
		return fromNodes(all)
	}
	split := min(maxChildren, total-minChildren)
	return fromNodes([]*node{fromNodes(all[:split]), fromNodes(all[split:])})
}

// mergeLeaves joins two leaves of which at least one is too small, into one leaf or two that
// are each big enough.
func mergeLeaves(a, b *node) *node {
	text := make([]byte, 0, a.length+b.length)
	text = append(append(text, a.text...), b.text...)
	if len(text) <= maxLeaf {
		return newLeaf(text)
	}
	at := splitPoint(text)
	return fromNodes([]*node{newLeaf(text[:at:at]), newLeaf(text[at:])})
}

// fromNodes returns an inner node over a copy of children, which share a height.
func fromNodes(children []*node) *node {
	n := &node{height: children[0].height + 1, children: make([]*node, len(children))}
	copy(n.children, children)
	for _, child := range children {
		n.length += child.length
		n.newlines += child.newlines
	}
	return n
}

// newLeaf returns a leaf over text, which it keeps.
func newLeaf(text []byte) *node {
	return &node{length: len(text), newlines: bytes.Count(text, newline), text: text}
}

// build returns a balanced tree holding a copy of text, or nil when text is empty.
func build(text []byte) *node {
	if len(text) == 0 {
		return nil
	}
	owned := make([]byte, len(text))
	copy(owned, text)
	var leaves []*node
	for len(owned) > maxLeaf {
		var at int
		if len(owned) <= 2*maxLeaf {
			at = splitPoint(owned)
		} else {
			at = cutPoint(owned)
		}
		leaves = append(leaves, newLeaf(owned[:at:at]))
		owned = owned[at:]
	}
	leaves = append(leaves, newLeaf(owned))
	for len(leaves) > 1 {
		parents := (len(leaves) + maxChildren - 1) / maxChildren
		level := make([]*node, 0, parents)
		for i := range parents {
			level = append(level, fromNodes(leaves[i*len(leaves)/parents:(i+1)*len(leaves)/parents]))
		}
		leaves = level
	}
	return leaves[0]
}

// splitPoint is where text of more than maxLeaf and at most 2*maxLeaf bytes splits into two
// leaves that are each between minLeaf and maxLeaf: after the line break nearest the middle
// when there is one in range, at the middle otherwise, never inside a UTF-8 sequence.
func splitPoint(text []byte) int {
	lo := max(minLeaf, len(text)-maxLeaf)
	hi := min(maxLeaf, len(text)-minLeaf)
	mid := min(max(len(text)/2, lo), hi)
	best := -1
	if i := bytes.IndexByte(text[mid:hi], '\n'); i >= 0 {
		best = mid + i + 1
	}
	if i := bytes.LastIndexByte(text[lo:mid], '\n'); i >= 0 {
		if at := lo + i + 1; best < 0 || mid-at < best-mid {
			best = at
		}
	}
	if best >= lo && best <= hi {
		return best
	}
	return runeBoundary(text, mid, lo, hi)
}

// cutPoint is where the first leaf of text, which is longer than 2*maxLeaf, ends: after the
// last line break in its last quarter, or at maxLeaf, never inside a UTF-8 sequence.
func cutPoint(text []byte) int {
	lo := maxLeaf - maxLeaf/4
	if i := bytes.LastIndexByte(text[lo:maxLeaf], '\n'); i >= 0 {
		return lo + i + 1
	}
	return runeBoundary(text, maxLeaf, lo, maxLeaf)
}

// runeBoundary moves at back to the start of the UTF-8 sequence it is in, or forward past it
// when going back would leave lo. Invalid UTF-8 is split anywhere after three tries.
func runeBoundary(text []byte, at, lo, hi int) int {
	for i := 0; i < utf8.UTFMax && at-i > lo; i++ {
		if utf8.RuneStart(text[at-i]) {
			return at - i
		}
	}
	for i := 1; i < utf8.UTFMax && at+i < hi; i++ {
		if utf8.RuneStart(text[at+i]) {
			return at + i
		}
	}
	return at
}
