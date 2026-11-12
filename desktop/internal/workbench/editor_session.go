package workbench

import (
	"os"
	"path/filepath"
	"slices"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/ui"
)

// A project reopens with the editor as it was left: the files open in each editor group, in
// their order, the split the groups were laid out in and its proportions, the tab each group
// showed, the group that had the keyboard, every file's caret and its pin. The session is
// written when the project closes (quitting closes it too) and read when it opens again.
// Terminals, diffs, viewers and plugin documents are not kept: their sessions end with the
// project. Files are kept relative to the project root, so a moved project keeps its session.

// editorSessionFile holds the sessions of the most recently closed projects, by root.
const editorSessionFile = "editor-sessions.json"

// editorSessionLimit is how many projects keep a session; the oldest goes first.
const editorSessionLimit = 40

// savedEditorFile is an open file: its path relative to the root with "/" separators, its
// caret as a zero-based line and UTF-16 column, and whether its tab was pinned.
type savedEditorFile struct {
	Path   string `json:"path"`
	Line   int    `json:"line"`
	Column int    `json:"column"`
	Pinned bool   `json:"pinned,omitempty"`
}

// savedEditorGroup is one tab group: its files in tab order and the one it showed.
type savedEditorGroup struct {
	ID       string            `json:"id"`
	Files    []savedEditorFile `json:"files"`
	Selected string            `json:"selected,omitempty"`
}

// savedEditorSplit is the layout of the groups: a leaf names a group; a container holds two
// children side by side (Row) or one over the other, the first taking Ratio of the room.
type savedEditorSplit struct {
	Group  string            `json:"group,omitempty"`
	Row    bool              `json:"row,omitempty"`
	Ratio  float32           `json:"ratio,omitempty"`
	First  *savedEditorSplit `json:"first,omitempty"`
	Second *savedEditorSplit `json:"second,omitempty"`
}

// savedEditorSession is the editor of one project when it closed.
type savedEditorSession struct {
	SavedAt time.Time          `json:"savedAt"`
	Layout  *savedEditorSplit  `json:"layout"`
	Groups  []savedEditorGroup `json:"groups"`
	Focused string             `json:"focused,omitempty"`
}

// editorRestore is a session being reopened, one file after another so each group lists its
// files in the saved order. groups are the groups made for it, selected the file each shows,
// pinned the files to pin and focused the group that takes the keyboard.
type editorRestore struct {
	items    []editorRestoreItem
	waiting  string
	groups   []string
	selected map[string]string
	pinned   []string
	focused  string
}

// editorRestoreItem is one file to reopen into group, with its caret.
type editorRestoreItem struct {
	path, group  string
	line, column int
}

// saveEditorSession records the editor of p for the next time the project opens. A project
// with no file open forgets its session.
func (a *App) saveEditorSession(p *project) {
	all := map[string]savedEditorSession{}
	if _, err := a.store.Load(editorSessionFile, &all); err != nil {
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("editor_session_load", documentLogError(err)))
		all = map[string]savedEditorSession{}
	}
	if session, ok := captureEditorSession(p); ok {
		session.SavedAt = a.now()
		all[p.root] = session
	} else {
		delete(all, p.root)
	}
	if len(all) > editorSessionLimit {
		roots := make([]string, 0, len(all))
		for root := range all {
			roots = append(roots, root)
		}
		slices.SortFunc(roots, func(x, y string) int { return all[y].SavedAt.Compare(all[x].SavedAt) })
		for _, root := range roots[editorSessionLimit:] {
			delete(all, root)
		}
	}
	if err := a.store.Save(editorSessionFile, all); err != nil {
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("editor_session_save", documentLogError(err)))
	}
}

// captureEditorSession reads the session of p from its groups and layout; false when no
// group shows a file of the project.
func captureEditorSession(p *project) (savedEditorSession, bool) {
	var session savedEditorSession
	var walk func(n *splitNode) *savedEditorSplit
	walk = func(n *splitNode) *savedEditorSplit {
		switch {
		case n == nil:
			return nil
		case n.leaf():
			group, ok := captureEditorGroup(p, n.group)
			if !ok {
				return nil
			}
			session.Groups = append(session.Groups, group)
			return &savedEditorSplit{Group: n.group}
		}
		first, second := walk(n.first), walk(n.second)
		switch {
		case first == nil:
			return second
		case second == nil:
			return first
		}
		return &savedEditorSplit{Row: n.row, Ratio: n.state.Ratio, First: first, Second: second}
	}
	session.Layout = walk(p.terms.layout)
	if len(session.Groups) == 0 {
		return savedEditorSession{}, false
	}
	if slices.ContainsFunc(session.Groups, func(g savedEditorGroup) bool { return g.ID == p.docs.group }) {
		session.Focused = p.docs.group
	}
	return session, true
}

// captureEditorGroup reads the project files group shows.
func captureEditorGroup(p *project, id string) (savedEditorGroup, bool) {
	g := p.terms.bench.Group(id)
	if g == nil {
		return savedEditorGroup{}, false
	}
	saved := savedEditorGroup{ID: id}
	for _, member := range g.Members {
		docID, ok := memberDocument(member)
		if !ok {
			continue
		}
		d := p.docs.find(docID)
		if d == nil || d.virtual {
			continue
		}
		rel, inside := projectRelative(p.root, d.path)
		if !inside {
			continue
		}
		line, column := d.view.CaretUTF16()
		saved.Files = append(saved.Files, savedEditorFile{Path: rel, Line: line, Column: column, Pinned: g.IsPinned(member)})
		if member == g.Selected {
			saved.Selected = rel
		}
	}
	return saved, len(saved.Files) > 0
}

// restoreEditorSession reopens the files p had open when it last closed. It runs once, as the
// project opens, before anything else is placed in the editor.
func (a *App) restoreEditorSession(p *project) {
	all := map[string]savedEditorSession{}
	if found, err := a.store.Load(editorSessionFile, &all); err != nil || !found {
		if err != nil {
			a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("editor_session_load", documentLogError(err)))
		}
		return
	}
	session, ok := all[p.root]
	if !ok || len(session.Groups) == 0 {
		return
	}
	set := &p.terms
	r := &editorRestore{selected: map[string]string{}}
	ids := map[string]string{}
	if set.layout == nil {
		// The saved groups are made empty, laid out as they were; the files then join them.
		state := set.bench
		state.Groups = slices.Clone(state.Groups)
		for _, g := range session.Groups {
			if _, dup := ids[g.ID]; dup {
				continue
			}
			set.nextGroup++
			id := editorGroupID(set.nextGroup)
			ids[g.ID] = id
			r.groups = append(r.groups, id)
			state.Groups = append(state.Groups, core.EditorGroup{ID: id})
		}
		layout := restoredSplit(set, session.Layout, ids)
		if layout == nil {
			return
		}
		set.bench = state
		set.layout = layout
		// A group the layout left out is not kept.
		for saved, id := range ids {
			if !layout.contains(id) {
				delete(ids, saved)
				a.dropRestoredGroup(p, id)
			}
		}
	}
	for _, g := range session.Groups {
		group := ids[g.ID]
		for _, f := range g.Files {
			path := filepath.Join(p.root, filepath.FromSlash(f.Path))
			if _, inside := projectRelative(p.root, path); !inside {
				continue
			}
			r.items = append(r.items, editorRestoreItem{path: path, group: group, line: f.Line, column: f.Column})
			if f.Pinned {
				r.pinned = append(r.pinned, path)
			}
		}
		if g.Selected != "" && group != "" {
			r.selected[group] = filepath.Join(p.root, filepath.FromSlash(g.Selected))
		}
	}
	r.focused = ids[session.Focused]
	p.docs.restore = r
	a.stepEditorRestore(p)
}

// restoredSplit makes the layout of a saved split for the groups made for it; a leaf whose
// group was not made is left out, and its sibling takes the room.
func restoredSplit(set *terminalSet, s *savedEditorSplit, ids map[string]string) *splitNode {
	if s == nil {
		return nil
	}
	if s.Group != "" {
		id, ok := ids[s.Group]
		if !ok {
			return nil
		}
		return newLeaf(id)
	}
	first, second := restoredSplit(set, s.First, ids), restoredSplit(set, s.Second, ids)
	switch {
	case first == nil:
		return second
	case second == nil:
		return first
	}
	ratio := s.Ratio
	if !(ratio > 0 && ratio < 1) {
		ratio = 0.5
	}
	set.nextNode++
	return &splitNode{id: set.nextNode, row: s.Row, first: first, second: second, state: ui.SplitterState{Ratio: ratio}}
}

// stepEditorRestore opens the next file of the session; a file being read continues the
// session when it arrives (openFinished). A file that is gone is skipped without a message.
func (a *App) stepEditorRestore(p *project) {
	r := p.docs.restore
	for r != nil && len(r.items) > 0 {
		item := r.items[0]
		r.items = r.items[1:]
		if info, err := os.Stat(item.path); err != nil || info.IsDir() || p.docs.byPath(item.path) != nil {
			continue
		}
		if p.docs.locations == nil {
			p.docs.locations = make(map[string]documentLocation)
		}
		p.docs.locations[item.path] = documentLocation{line: item.line + 1, column: item.column, columnSet: true, group: item.group}
		a.openFile(p, item.path)
		if p.docs.opening[item.path] {
			r.waiting = item.path
			return
		}
		delete(p.docs.locations, item.path)
	}
	if r != nil {
		p.docs.restore = nil
		a.finishEditorRestore(p, r)
	}
}

// continueEditorRestore goes on with the session once the file it waited for is placed.
func (a *App) continueEditorRestore(p *project, path string) {
	if r := p.docs.restore; r != nil && r.waiting == path {
		r.waiting = ""
		a.stepEditorRestore(p)
	}
}

// finishEditorRestore pins the pinned files, shows each group's tab, removes the groups no
// file reached and gives the keyboard to the focused group's file.
func (a *App) finishEditorRestore(p *project, r *editorRestore) {
	if a.project != p {
		return
	}
	for _, path := range r.pinned {
		if d := p.docs.byPath(path); d != nil {
			member := documentMember(d.id)
			if g := p.terms.bench.GroupOf(member); g != nil {
				a.reduceTerminals(p, p.terms.bench, core.PinEditor(g.ID, member, true))
			}
		}
	}
	for _, id := range r.groups {
		g := p.terms.bench.Group(id)
		if g == nil {
			continue
		}
		if len(g.Members) == 0 {
			a.dropRestoredGroup(p, id)
			continue
		}
		if d := p.docs.byPath(r.selected[id]); d != nil && slices.Contains(g.Members, documentMember(d.id)) {
			a.reduceTerminals(p, p.terms.bench, core.ActivateEditor(id, documentMember(d.id)))
		}
	}
	focused := r.focused
	if p.terms.bench.Group(focused) == nil {
		focused = firstEditorGroup(p.terms.layout)
	}
	if g := p.terms.bench.Group(focused); g != nil {
		if id, ok := memberDocument(g.Selected); ok {
			a.selectDocument(p, id)
		}
	}
}

// dropRestoredGroup removes a group made for the session that no file reached.
func (a *App) dropRestoredGroup(p *project, id string) {
	set := &p.terms
	set.bench.Groups = slices.DeleteFunc(slices.Clone(set.bench.Groups), func(g core.EditorGroup) bool { return g.ID == id })
	set.layout = removeLeaf(set.layout, id)
}
