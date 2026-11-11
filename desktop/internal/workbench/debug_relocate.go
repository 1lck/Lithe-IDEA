package workbench

import (
	"context"
	"slices"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/rope"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
)

// relocateDocumentBreakpoints moves the breakpoints of a file across one edit of it, so a line
// that is typed above a breakpoint keeps the breakpoint on its statement. Core decides where
// each breakpoint lands; the host gives it the text before the edit and the edit in UTF-16
// offsets. The text before the edit is the one the document last had, so every edit updates it,
// with or without breakpoints. Relocation runs only when the file has breakpoints.
func (a *App) relocateDocumentBreakpoints(p *project, d *document, edit editorview.Edit) {
	before := d.breakpointText
	d.breakpointText = d.view.TextSnapshot()
	if p == nil || a.project != p || d.path == "" || len(p.debug.breakpoints[d.path]) == 0 || before.Len() == 0 {
		return
	}
	startLine, endLine := edit.StartLine, edit.EndLine
	start, okStart := utf16OffsetOf(before, startLine, edit.StartColumn)
	end, okEnd := utf16OffsetOf(before, endLine, edit.EndColumn)
	if !okStart || !okEnd || end < start {
		// The edit names a place the text before it does not have: the breakpoints stay where
		// they are rather than move to a guessed line.
		return
	}
	lines := p.debug.breakpoints[d.path]
	ctx, cancel := context.WithTimeout(p.ctx, kernelCallTimeout)
	moved, err := a.kernel.RelocateDebugBreakpoints(ctx, before.String(), core.DebugTextEdit{
		StartUTF16Offset: int64(start),
		EndUTF16Offset:   int64(end),
		Replacement:      edit.Text,
	}, sourceBreakpoints(lines))
	cancel()
	if err != nil {
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("debug_relocate", err))
		return
	}
	next := make([]debugBreakpoint, 0, len(moved))
	for _, point := range moved {
		next = append(next, debugBreakpoint{
			line:         point.Line,
			condition:    point.Condition,
			hitCondition: point.HitCondition,
			logMessage:   point.LogMessage,
		})
	}
	slices.SortFunc(next, func(x, y debugBreakpoint) int { return int(x.line - y.line) })
	if len(next) == 0 {
		delete(p.debug.breakpoints, d.path)
	} else {
		p.debug.breakpoints[d.path] = next
	}
	if p.debug.session != nil {
		a.sendDebugBreakpoints(p, d.path)
	}
}

// utf16OffsetOf converts a zero-based line and UTF-16 column into an offset in UTF-16 units
// from the start of text. It reports false for a line the text does not have.
func utf16OffsetOf(text rope.Rope, line, column int) (int, bool) {
	if line < 0 || line >= text.LineCount() {
		return 0, false
	}
	prefix, ok := text.Substring(0, text.LineStart(line))
	if !ok {
		return 0, false
	}
	units := 0
	for _, r := range prefix {
		units++
		if r > 0xffff {
			units++
		}
	}
	return units + column, true
}
