package workbench

import (
	"bytes"
	"sort"
	"strconv"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
)

// This file is the model of a Diff tab laid out as editors. From the unified lines Core reads
// for a file it builds the text of the two panes, the before and the after version side by
// side, or the one pane of the unified mode, together with what the editors draw over that
// text: the gutter label of each line, the tinted ranges of the changes, the notes of the
// folds and the hunk separators. It also keeps the fragments, the ranges of the two panes
// that correspond, which the view connects and which keep the scroll of the panes in step. It
// draws nothing and holds no state of a tab.

const (
	// diffModified marks the lines of a change that replaces lines with others.
	diffModified diffKind = diffAdded + 1
	// diffFolded marks the placeholder of a fold and the separator of a hunk, the lines that
	// stand for no line of the file.
	diffFolded diffKind = diffModified + 1
)

// diffSpan is a range of a pane's lines, from start to end, end excluded. Lines are counted
// from zero.
type diffSpan struct{ start, end int }

// empty says the span covers no line.
func (s diffSpan) empty() bool { return s.end <= s.start }

// diffFragment is a change of the file as the two panes hold it: the range of the before pane
// and the range of the after pane that correspond. A pure insertion has an empty before span
// and a pure deletion an empty after span. In the unified mode both spans are the same range
// of the one pane.
type diffFragment struct {
	before, after diffSpan
	kind          diffKind
	// block is the block of Core the change belongs to; nil when Core named none.
	block *core.DiffBlock
	// number is the 1-based position of the block among the blocks met so far; 0 when block is
	// nil.
	number int
}

// diffFold is a run of unchanged lines that the panes replace with one placeholder line.
type diffFold struct {
	// before and after are the pane line of the placeholder on each side. In the unified mode
	// both are the same line of the one pane.
	before, after int
	// at is the index among the unified lines of the first line of the run: the key under which
	// the tab remembers the fold as expanded.
	at int
	// hidden is how many lines the fold hides.
	hidden int
}

// diffMark is a range of a pane that the editor tints by kind, or a rule drawn at the top of
// the line where an insertion or a deletion of the other pane falls.
type diffMark struct {
	span diffSpan
	kind diffKind
	// boundary says the mark is a rule at the top of span.start, because the pane has no line
	// of the change; span is empty then.
	boundary bool
}

// diffPane is what one editor of a Diff tab shows: its text and the marks, labels and notes
// the editor draws over it.
type diffPane struct {
	// text is the lines of the pane joined with a line break; no break ends the last line.
	text []byte
	// labels is the gutter label of each line. A pane has at least one line, as an editor does.
	labels []string
	// marks are the tinted ranges and the rules, in the order of the lines.
	marks []diffMark
	// notes are the texts shown at the end of a line, in the order of the lines.
	notes []editorview.LineAnnotation
}

// lineCount is how many lines the pane has, which is at least one.
func (p *diffPane) lineCount() int { return len(p.labels) }

// diffLayout is a file's diff laid out for the editors of a Diff tab.
type diffLayout struct {
	// split says the before and the after pane are both filled; otherwise only after is, with
	// the changed lines of both versions in it, and before is the zero value.
	split         bool
	before, after diffPane
	// fragments are the changes of the file, in the order of the lines.
	fragments []diffFragment
	// folds are the folded runs of unchanged lines, in the order of the lines.
	folds []diffFold
}

// layoutDiff lays out the unified lines of a file as the panes of a Diff tab, side by side
// when split and as one pane otherwise. anchors names the block that starts at a line index:
// Core names a block by the first removed line of its change run, else the first added one.
// Unchanged lines far from any change fold into a placeholder unless whole is set; a fold the
// tab has opened is in expanded, by the index of its first line, which may be nil. foldText
// makes the note of a placeholder from the number of lines it hides.
func layoutDiff(lines []core.GitDiffLine, anchors map[int]*core.DiffBlock, split, whole bool, expanded map[int]bool, foldText func(hidden int) string) *diffLayout {
	b := &diffLayoutBuilder{split: split, foldText: foldText}
	size := 0
	for _, line := range lines {
		size += len(line.Content) + 1
	}
	b.after.reserve(size, len(lines))
	if split {
		b.before.reserve(size, len(lines))
	} else {
		b.width = diffNumberWidth(lines)
	}

	blocks := 0
	for i := 0; i < len(lines); {
		line := lines[i]
		switch {
		case line.LineType == "context" && !whole && anchors[i] == nil:
			j := i + 1
			for j < len(lines) && lines[j].LineType == "context" && anchors[j] == nil {
				j++
			}
			b.plain(lines, i, j, expanded[i])
			i = j
		case line.LineType == "context":
			b.context(line)
			i++
		case line.LineType == "header":
			if b.emitted() || !diffStartsAtOne(lines, i+1) {
				b.placeholder(line.Content)
			}
			i++
		case line.LineType == "added" || line.LineType == "removed":
			j := i + 1
			for j < len(lines) && (lines[j].LineType == "added" || lines[j].LineType == "removed") {
				j++
			}
			var block *core.DiffBlock
			for k := i; k < j && block == nil; k++ {
				block = anchors[k]
			}
			number := 0
			if block != nil {
				blocks++
				number = blocks
			}
			b.change(lines[i:j], block, number)
			i = j
		default:
			i++
		}
	}

	layout := &diffLayout{split: split, after: b.after.done(), fragments: b.fragments, folds: b.folds}
	if split {
		layout.before = b.before.done()
	}
	return layout
}

// diffStartsAtOne says the line at index i exists and is the first line of the file in the old
// or the new version: the hunk that begins there starts at the top of the file.
func diffStartsAtOne(lines []core.GitDiffLine, i int) bool {
	if i >= len(lines) {
		return false
	}
	line := lines[i]
	return (line.OldLine != nil && *line.OldLine == 1) || (line.NewLine != nil && *line.NewLine == 1)
}

// diffChangeKind is the kind of a change that has lines in the before version, in the after
// version, or in both.
func diffChangeKind(inBefore, inAfter bool) diffKind {
	switch {
	case inBefore && inAfter:
		return diffModified
	case inAfter:
		return diffAdded
	default:
		return diffRemoved
	}
}

// diffNumberWidth is the number of digits of the largest line number among the lines, and at
// least one: the width of each of the two numbers of a unified gutter label.
func diffNumberWidth(lines []core.GitDiffLine) int {
	largest := 0
	for _, line := range lines {
		if line.OldLine != nil && *line.OldLine > largest {
			largest = *line.OldLine
		}
		if line.NewLine != nil && *line.NewLine > largest {
			largest = *line.NewLine
		}
	}
	return len(strconv.Itoa(largest))
}

// diffNumberLabel is the gutter label of a line in a side by side pane: its number, or
// nothing when the line has none.
func diffNumberLabel(number *int) string {
	if number == nil {
		return ""
	}
	return strconv.Itoa(*number)
}

// diffUnifiedLabel is the gutter label of a line of the unified pane: the old and the new
// number, each padded with spaces to width, and a line that has no such number gets spaces
// instead.
func diffUnifiedLabel(oldNumber, newNumber *int, width int) string {
	var label strings.Builder
	label.Grow(2*width + 1)
	pad := func(number *int) {
		text := diffNumberLabel(number)
		for n := width - len(text); n > 0; n-- {
			label.WriteByte(' ')
		}
		label.WriteString(text)
	}
	pad(oldNumber)
	label.WriteByte(' ')
	pad(newNumber)
	return label.String()
}

// diffPaneBuilder collects the lines, marks and notes of one pane.
type diffPaneBuilder struct {
	text   bytes.Buffer
	labels []string
	marks  []diffMark
	notes  []editorview.LineAnnotation
}

// reserve makes room for about size bytes of text and lines lines.
func (b *diffPaneBuilder) reserve(size, lines int) {
	b.text.Grow(size)
	b.labels = make([]string, 0, lines)
}

// line adds a line with its gutter label and returns its index in the pane.
func (b *diffPaneBuilder) line(text, label string) int {
	if len(b.labels) > 0 {
		b.text.WriteByte('\n')
	}
	b.text.WriteString(text)
	b.labels = append(b.labels, label)
	return len(b.labels) - 1
}

// count is how many lines the pane has so far.
func (b *diffPaneBuilder) count() int { return len(b.labels) }

// mark adds a tinted range, or a rule when the span is empty.
func (b *diffPaneBuilder) mark(span diffSpan, kind diffKind) {
	b.marks = append(b.marks, diffMark{span: span, kind: kind, boundary: span.empty()})
}

// placeholder adds an empty line without a label that carries a note and a folded mark, and
// returns its index: the line a fold or a hunk separator takes in the pane. Its note has the
// icon of unfolding and a rule after it, as IDEA draws a fold.
func (b *diffPaneBuilder) placeholder(text string) int {
	line := b.line("", "")
	b.notes = append(b.notes, editorview.LineAnnotation{Line: line, Text: text, Icon: icons.UnfoldVertical, Rule: true})
	b.mark(diffSpan{line, line + 1}, diffFolded)
	return line
}

// done is the pane that was collected. A pane without a line gets the one empty line an
// editor always has; the rules of its boundary marks stay, at the top of that line.
func (b *diffPaneBuilder) done() diffPane {
	if len(b.labels) == 0 {
		return diffPane{labels: []string{""}, marks: b.marks, notes: b.notes}
	}
	return diffPane{text: b.text.Bytes(), labels: b.labels, marks: b.marks, notes: b.notes}
}

// diffLayoutBuilder collects a layout: the panes, and the fragments and folds that go with
// them.
type diffLayoutBuilder struct {
	split bool
	// width is the width of each number of a unified gutter label.
	width         int
	foldText      func(hidden int) string
	before, after diffPaneBuilder
	fragments     []diffFragment
	folds         []diffFold
}

// emitted says a line has been written to a pane.
func (b *diffLayoutBuilder) emitted() bool { return b.before.count()+b.after.count() > 0 }

// context writes an unchanged line.
func (b *diffLayoutBuilder) context(line core.GitDiffLine) {
	if b.split {
		b.before.line(line.Content, diffNumberLabel(line.OldLine))
		b.after.line(line.Content, diffNumberLabel(line.NewLine))
		return
	}
	b.after.line(line.Content, diffUnifiedLabel(line.OldLine, line.NewLine, b.width))
}

// placeholder writes a line that stands for no line of the file with the note, on both panes
// of a side by side layout and on the one pane of a unified one, and returns its line in
// each. The two are the same line in the unified mode.
func (b *diffLayoutBuilder) placeholder(text string) (before, after int) {
	if !b.split {
		after = b.after.placeholder(text)
		return after, after
	}
	before = b.before.placeholder(text)
	after = b.after.placeholder(text)
	return before, after
}

// plain writes the run of unchanged lines from i to j, end excluded, of a file that has no
// anchor on them: all of them when the run is short or open, else the few next to the
// changes around it, with a fold between.
func (b *diffLayoutBuilder) plain(lines []core.GitDiffLine, i, j int, open bool) {
	head, tail := diffContext, diffContext
	if !b.emitted() {
		head = 0
	}
	if j == len(lines) {
		tail = 0
	}
	hidden := j - i - head - tail
	if hidden < diffFoldLeast || open {
		for _, line := range lines[i:j] {
			b.context(line)
		}
		return
	}
	for _, line := range lines[i : i+head] {
		b.context(line)
	}
	text := ""
	if b.foldText != nil {
		text = b.foldText(hidden)
	}
	before, after := b.placeholder(text)
	b.folds = append(b.folds, diffFold{before: before, after: after, at: i, hidden: hidden})
	for _, line := range lines[j-tail : j] {
		b.context(line)
	}
}

// change writes a run of added and removed lines and the fragment that stands for it.
func (b *diffLayoutBuilder) change(run []core.GitDiffLine, block *core.DiffBlock, number int) {
	if !b.split {
		b.changeUnified(run, block, number)
		return
	}
	beforeStart, afterStart := b.before.count(), b.after.count()
	for _, line := range run {
		if line.LineType == "removed" {
			b.before.line(line.Content, diffNumberLabel(line.OldLine))
		} else {
			b.after.line(line.Content, diffNumberLabel(line.NewLine))
		}
	}
	before := diffSpan{beforeStart, b.before.count()}
	after := diffSpan{afterStart, b.after.count()}
	kind := diffChangeKind(!before.empty(), !after.empty())
	b.before.mark(before, kind)
	b.after.mark(after, kind)
	b.fragments = append(b.fragments, diffFragment{before: before, after: after, kind: kind, block: block, number: number})
}

// changeUnified writes a run of added and removed lines to the one pane, in their order, and
// the fragment that stands for it. Neighbors of the same type share a mark.
func (b *diffLayoutBuilder) changeUnified(run []core.GitDiffLine, block *core.DiffBlock, number int) {
	start := b.after.count()
	markStart, markKind := start, diffSame
	removed, added := false, false
	for _, line := range run {
		kind := diffAdded
		if line.LineType == "removed" {
			kind = diffRemoved
			removed = true
		} else {
			added = true
		}
		at := b.after.line(line.Content, diffUnifiedLabel(line.OldLine, line.NewLine, b.width))
		if kind != markKind {
			if at > markStart {
				b.after.mark(diffSpan{markStart, at}, markKind)
			}
			markStart, markKind = at, kind
		}
	}
	b.after.mark(diffSpan{markStart, b.after.count()}, markKind)
	span := diffSpan{start, b.after.count()}
	b.fragments = append(b.fragments, diffFragment{before: span, after: span, kind: diffChangeKind(removed, added), block: block, number: number})
}

// mapLine is the place in the other pane that matches place y of one pane, in lines with a
// fraction: of the after pane for y of the before pane when fromBefore, else the reverse. A
// place inside a change maps in proportion to the two ranges, and one in the unchanged lines
// between changes moves along with them. It is meant for the side by side layout; in the
// unified one it returns y.
func (l *diffLayout) mapLine(y float64, fromBefore bool) float64 {
	if !l.split {
		return y
	}
	// spans is the source and the target range of a fragment.
	spans := func(f diffFragment) (source, target diffSpan) {
		if fromBefore {
			return f.before, f.after
		}
		return f.after, f.before
	}
	k := sort.Search(len(l.fragments), func(k int) bool {
		source, _ := spans(l.fragments[k])
		return float64(source.end) > y
	})
	prevSource, prevTarget := 0, 0
	if k > 0 {
		source, target := spans(l.fragments[k-1])
		prevSource, prevTarget = source.end, target.end
	}
	if k == len(l.fragments) {
		return y - float64(prevSource) + float64(prevTarget)
	}
	source, target := spans(l.fragments[k])
	if y < float64(source.start) {
		return y - float64(prevSource) + float64(prevTarget)
	}
	ratio := float64(target.end-target.start) / float64(source.end-source.start)
	return float64(target.start) + (y-float64(source.start))*ratio
}

// foldAt is the fold whose placeholder is pane line line, of the before pane when before, else
// of the after pane.
func (l *diffLayout) foldAt(line int, before bool) (diffFold, bool) {
	at := func(f diffFold) int {
		if before {
			return f.before
		}
		return f.after
	}
	k := sort.Search(len(l.folds), func(k int) bool { return at(l.folds[k]) >= line })
	if k < len(l.folds) && at(l.folds[k]) == line {
		return l.folds[k], true
	}
	return diffFold{}, false
}
