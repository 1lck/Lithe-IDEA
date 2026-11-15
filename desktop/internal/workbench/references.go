package workbench

import (
	"context"
	"os"
	"path/filepath"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/ui"
)

// The References tool window: the answer of Find Usages as a list grouped by file, each row
// showing its position and the line it points at.
//
// Core normalizes the locations; this file groups them by file in the order the server gave
// them, reads the lines to show in the background (an open file's from its editor, a closed
// one's from disk, bounded), and opens a row's file at its position.

const (
	// referencePreviewLimit bounds how much of one closed file is read to show its lines.
	referencePreviewLimit = 2 << 20
	// referencePreviewWidth cuts a shown line, in bytes.
	referencePreviewWidth = 240
	referenceRowHeight    = 22
)

// usageGroup is the references that lie in one file.
type usageGroup struct {
	path    string
	display string
	// indices point into the state's targets.
	indices []int
}

// referencesState is the References tool window's answer.
type referencesState struct {
	project *project
	targets []core.PluginSemanticLocation
	groups  []usageGroup
	// starts holds the flat row index of each group's header; rows is the row count.
	starts []int
	rows   int
	// previews is the line of each target, in step with targets; empty until read.
	previews   []string
	generation uint64
	list       ui.ListState
	// symbol is what was searched for, shown as the window's subtitle.
	symbol string
}

// rowAt locates a flat row: a group header, or the reference at index of group.
func (s *referencesState) rowAt(row int) (group, index int, header bool) {
	if row < 0 || row >= s.rows {
		return 0, 0, false
	}
	for g := len(s.starts) - 1; g >= 0; g-- {
		if row >= s.starts[g] {
			offset := row - s.starts[g]
			return g, offset - 1, offset == 0
		}
	}
	return 0, 0, false
}

// showReferences makes targets the contents of the References tool window and opens it.
func (a *App) showReferences(p *project, targets []core.PluginSemanticLocation, symbol string) {
	s := &a.editor.refs
	s.generation++
	s.project, s.targets, s.symbol = p, targets, symbol
	s.groups, s.starts, s.rows = s.groups[:0], s.starts[:0], 0
	s.previews = make([]string, len(targets))
	s.list = ui.ListState{}
	byPath := map[string]int{}
	for i, target := range targets {
		key := target.FilePath
		if key == "" {
			key = target.URI
		}
		g, ok := byPath[key]
		if !ok {
			display := key
			if rel, err := filepath.Rel(p.root, key); err == nil && !strings.HasPrefix(rel, "..") {
				display = rel
			}
			g = len(s.groups)
			byPath[key] = g
			s.groups = append(s.groups, usageGroup{path: target.FilePath, display: display})
		}
		s.groups[g].indices = append(s.groups[g].indices, i)
	}
	for _, g := range s.groups {
		s.starts = append(s.starts, s.rows)
		s.rows += 1 + len(g.indices)
	}
	a.reduceChrome(core.SetChromeOpen(itemReferences, true))
	a.loadReferencePreviews(p, s.generation)
}

// loadReferencePreviews reads the line of every reference. An open file's lines come from its
// editor on the window thread, which only reads rope lines; closed files are read off it.
func (a *App) loadReferencePreviews(p *project, generation uint64) {
	s := &a.editor.refs
	var closed []usageGroup
	for _, g := range s.groups {
		if g.path == "" {
			continue
		}
		if d := p.docs.byPath(g.path); d != nil {
			text := d.view.TextSnapshot()
			for _, i := range g.indices {
				if line := s.targets[i].Range.Start.Line; line >= 0 && line < text.LineCount() {
					s.previews[i] = previewLine(text.Line(line))
				}
			}
			continue
		}
		closed = append(closed, g)
	}
	if len(closed) == 0 {
		return
	}
	targets := s.targets
	a.background(p, 0, func(context.Context) func(*App) {
		previews := make(map[int]string)
		for _, g := range closed {
			lines := readLines(g.path, referencePreviewLimit)
			for _, i := range g.indices {
				if line := targets[i].Range.Start.Line; line >= 0 && line < len(lines) {
					previews[i] = previewLine(lines[line])
				}
			}
		}
		return func(a *App) {
			s := &a.editor.refs
			if s.generation != generation || s.project != p {
				return
			}
			for i, text := range previews {
				if i < len(s.previews) {
					s.previews[i] = text
				}
			}
			a.invalidator.Invalidate()
		}
	})
}

// readLines is the lines of the file at path, read up to limit bytes; nil when it cannot be
// read.
func readLines(path string, limit int64) []string {
	file, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer file.Close()
	buf := make([]byte, limit)
	n, _ := file.Read(buf)
	return strings.Split(string(buf[:n]), "\n")
}

// previewLine is a line trimmed of its indentation and its carriage return and cut to a width
// that fits a row.
func previewLine(line string) string {
	line = strings.TrimSpace(strings.TrimSuffix(line, "\r"))
	if len(line) > referencePreviewWidth {
		line = line[:referencePreviewWidth]
		for len(line) > 0 && line[len(line)-1]&0xC0 == 0x80 {
			line = line[:len(line)-1]
		}
	}
	return line
}

// openReference opens the file of a target at its position.
func (a *App) openReference(p *project, target core.PluginSemanticLocation) {
	a.openDefinitionTarget(target)
	_ = p
}
