package workbench

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/syntax"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/logwindow"
	"github.com/vivaui/viva/flex"
	"github.com/vivaui/viva/ui"
)

const (
	// documentMemberPrefix starts the member name of an open file in a tab group: "file:3".
	documentMemberPrefix = "file:"
	// documentMaxBytes is the largest file the editor opens, and documentSniff how much of
	// the start of a file is searched for the NUL byte that marks it as binary.
	documentMaxBytes = 16 << 20
	documentSniff    = 8 << 10
	// documentDirty is the side of the dot a tab shows while its file has unsaved changes.
	documentDirty = 6

	// The log events of a file that could not be opened or saved.
	documentEventOpenFailed = "editor.document.open_failed"
	documentEventSaveFailed = "editor.document.save_failed"
)

// The identities of the open files' controls. Each is a scope whose At(n) is the control of
// the document with id n: docTabs its tab, docClose its tab's close button and docViews its
// text, which holds the keyboard focus.
var (
	docTabs  = tree.Sub(shellPage, tree.Name("document-tabs"))
	docClose = tree.Sub(shellPage, tree.Name("document-close"))
	docViews = tree.Sub(shellPage, tree.Name("document-views"))
)

// errNotText and errTooLarge are why a file is not opened, besides the system's errors.
var (
	errNotText  = errors.New("not a text file")
	errTooLarge = errors.New("file too large")
)

// document is a file open in a tab of the editor area.
type document struct {
	// id identifies the document for as long as the project is open; it is never reused.
	id int
	// path is the file's absolute path, and name its base name, which is the tab's title.
	path, name string
	view       *editorview.View
}

// documentSet is the files a project has open. The zero value has none.
type documentSet struct {
	list []*document
	next int
	// opening are the paths being read, so a second click while one is read opens nothing.
	opening map[string]bool
	// group is the editor group a document was last shown or focused in, where the next file
	// opens while it is still there.
	group string
}

// find is the document with id, and nil when there is none.
func (s *documentSet) find(id int) *document {
	for _, d := range s.list {
		if d.id == id {
			return d
		}
	}
	return nil
}

// byPath is the open document of the file at path, and nil when it is not open.
func (s *documentSet) byPath(path string) *document {
	for _, d := range s.list {
		if d.path == path {
			return d
		}
	}
	return nil
}

// documentMember is the name of document id as a member of a tab group.
func documentMember(id int) string { return documentMemberPrefix + strconv.Itoa(id) }

// memberDocument is the document id a group member names, and false for a member that does
// not name one.
func memberDocument(member string) (int, bool) {
	rest, ok := strings.CutPrefix(member, documentMemberPrefix)
	if !ok {
		return 0, false
	}
	id, err := strconv.Atoi(rest)
	return id, err == nil && id > 0
}

// selectedDocument is the document group shows, and nil when it shows a terminal or none.
func (p *project) selectedDocument(group string) *document {
	g := p.terms.bench.Group(group)
	if g == nil {
		return nil
	}
	if id, ok := memberDocument(g.Selected); ok {
		return p.docs.find(id)
	}
	return nil
}

// syntaxRegistry is the languages the editor knows, made the first time a file is opened.
func (a *App) syntaxRegistry() *syntax.Registry {
	if a.languages == nil {
		a.languages = syntax.NewRegistry()
	}
	return a.languages
}

// openFile shows the file at path in the editor: its tab if it is open already, or else a new
// tab in the editor group the last file was shown in, which is made when the editor has no
// group. The file is read and its language's grammar loaded away from the window thread; a
// file that cannot be read, is binary or is too large is not opened and the banner says why.
func (a *App) openFile(p *project, path string) {
	if d := p.docs.byPath(path); d != nil {
		a.selectDocument(p, d.id)
		return
	}
	if p.docs.opening[path] {
		return
	}
	if p.docs.opening == nil {
		p.docs.opening = map[string]bool{}
	}
	p.docs.opening[path] = true
	registry := a.syntaxRegistry()
	name := filepath.Base(path)
	a.background(p, 0, func(context.Context) func(*App) {
		data, err := readDocument(path)
		var grammar *syntax.Syntax
		if err == nil {
			if language, ok := registry.ForPath(path); ok {
				grammar = registry.Syntax(language.ID)
			}
		}
		return func(a *App) {
			delete(p.docs.opening, path)
			if err != nil {
				fields := logwindow.ErrorFields(err)
				fields["extension"] = filepath.Ext(path)
				a.emit(core.LevelWarn, documentEventOpenFailed, fields)
				a.notify(a.text.Editor.OpenFailed(name, a.documentReason(err)))
				return
			}
			a.placeDocument(p, path, name, data, grammar)
		}
	})
}

// readDocument reads the file at path for the editor, refusing one that is too large or
// holds a NUL byte near its start, the mark of a binary file.
func readDocument(path string) ([]byte, error) {
	info, err := os.Stat(path)
	if err != nil {
		return nil, err
	}
	if info.Size() > documentMaxBytes {
		return nil, errTooLarge
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	if bytes.IndexByte(data[:min(len(data), documentSniff)], 0) >= 0 {
		return nil, errNotText
	}
	return data, nil
}

// documentReason is the words for why a file could not be opened or saved: the editor's own
// reasons in the current language, and the system's message for the others.
func (a *App) documentReason(err error) string {
	switch {
	case errors.Is(err, errNotText):
		return a.text.Editor.NotText
	case errors.Is(err, errTooLarge):
		return a.text.Editor.TooLarge
	}
	var pathErr *os.PathError
	if errors.As(err, &pathErr) {
		return pathErr.Err.Error()
	}
	return err.Error()
}

// placeDocument opens a read file as a new tab, shown and given the keyboard.
func (a *App) placeDocument(p *project, path, name string, data []byte, grammar *syntax.Syntax) {
	if d := p.docs.byPath(path); d != nil {
		a.selectDocument(p, d.id)
		return
	}
	set := &p.terms
	state := set.bench
	group, added := a.documentGroup(p), ""
	if group == "" {
		added = editorGroupID(set.nextGroup + 1)
		state.Groups = append(slices.Clone(state.Groups), core.EditorGroup{ID: added})
		group = added
	}
	id := p.docs.next + 1
	if !a.reduceTerminals(p, state, core.OpenEditor(group, documentMember(id), true)) {
		return
	}
	p.docs.next = id
	if added != "" {
		set.nextGroup++
		set.layout = newLeaf(added)
	}
	d := &document{id: id, path: path, name: name}
	d.view = editorview.New(editorview.Config{
		HitID:  docViews.At(id),
		Label:  name,
		Text:   data,
		Syntax: grammar,
		Notify: a.invalidator.Invalidate,
		Save:   func() { a.saveDocument(p, id) },
	})
	p.docs.list = append(p.docs.list, d)
	p.docs.group = group
	a.focusDocument(id)
}

// documentGroup is the editor group a file opens in: the one a document was last shown in,
// while it is still there, or else the first group of the editor; "" when it has none.
func (a *App) documentGroup(p *project) string {
	set := &p.terms
	if g := p.docs.group; g != "" && set.layout.contains(g) && set.bench.Group(g) != nil {
		return g
	}
	n := set.layout
	for n != nil && !n.leaf() {
		n = n.first
	}
	if n == nil {
		return ""
	}
	return n.group
}

// selectDocument shows document id in its group and gives it the keyboard.
func (a *App) selectDocument(p *project, id int) {
	member := documentMember(id)
	g := p.terms.bench.GroupOf(member)
	if g == nil {
		return
	}
	if g.Selected != member && !a.reduceTerminals(p, p.terms.bench, core.ActivateEditor(g.ID, member)) {
		return
	}
	p.docs.group = g.ID
	a.focusDocument(id)
}

// focusDocument asks for the keyboard to go to document id as soon as it is painted.
func (a *App) focusDocument(id int) {
	a.term.docFocus, a.term.focusAge = id, 0
	a.term.focus = 0
}

// saveDocument writes document id's text to its file, away from the window thread, and
// marks what was written as saved once it is.
func (a *App) saveDocument(p *project, id int) {
	d := p.docs.find(id)
	if d == nil || !d.view.Dirty() {
		return
	}
	data, text := d.view.Text()
	path, name := d.path, d.name
	a.background(p, 0, func(context.Context) func(*App) {
		err := writeDocument(path, data)
		return func(a *App) {
			if err != nil {
				a.saveFailed(name, path, err)
				return
			}
			if d := p.docs.find(id); d != nil {
				d.view.MarkSaved(text)
			}
		}
	})
}

// writeDocument writes data over the file at path, keeping its permissions.
func writeDocument(path string, data []byte) error {
	mode := os.FileMode(0o644)
	if info, err := os.Stat(path); err == nil {
		mode = info.Mode().Perm()
	}
	return os.WriteFile(path, data, mode)
}

// saveFailed logs and shows that the file name could not be saved.
func (a *App) saveFailed(name, path string, err error) {
	fields := logwindow.ErrorFields(err)
	fields["extension"] = filepath.Ext(path)
	a.emit(core.LevelWarn, documentEventSaveFailed, fields)
	a.notify(a.text.Editor.SaveFailed(name, a.documentReason(err)))
}

// closeDocument saves document id if it has changes and removes its tab; the group shows
// the neighbouring tab instead. A file that cannot be saved keeps its tab, so no change is
// lost.
func (a *App) closeDocument(p *project, id int) {
	d := p.docs.find(id)
	if d == nil {
		return
	}
	if d.view.Dirty() {
		data, text := d.view.Text()
		if err := writeDocument(d.path, data); err != nil {
			a.saveFailed(d.name, d.path, err)
			return
		}
		d.view.MarkSaved(text)
	}
	member := documentMember(id)
	g := p.terms.bench.GroupOf(member)
	if g == nil {
		return
	}
	group := g.ID
	if !a.reduceTerminals(p, p.terms.bench, core.CloseEditor(group, member, emptyPolicy(group), core.SelectAdjacent)) {
		return
	}
	d.view.Close()
	p.docs.list = slices.DeleteFunc(p.docs.list, func(x *document) bool { return x.id == id })
	if next := p.selectedDocument(group); next != nil {
		a.focusDocument(next.id)
	} else if t := p.terms.selected(group); t != nil {
		a.focusTerminal(t.id)
	}
}

// closeDocuments saves the changes of a project that is being closed and closes its files.
// A file that cannot be saved is reported; the project closes anyway.
func (a *App) closeDocuments(p *project) {
	if p == nil {
		return
	}
	for _, d := range p.docs.list {
		if d.view.Dirty() {
			data, _ := d.view.Text()
			if err := writeDocument(d.path, data); err != nil {
				a.saveFailed(d.name, d.path, err)
			}
		}
		d.view.Close()
	}
	p.docs = documentSet{}
}

// editorLook is the editor's colors for the frame being painted, in the workbench theme
// with the terminal's caret and selection colors.
func (a *App) editorLook() editorview.Look {
	terminal := a.terminalLook()
	line := a.colors.Hover
	line.Alpha *= 0.6
	bar := a.colors.Subtle
	bar.Alpha *= 0.45
	return editorview.Look{
		Dark:        a.colors.Dark,
		Background:  a.colors.Editor,
		Foreground:  a.colors.Text,
		Subtle:      a.colors.Subtle,
		CurrentLine: line,
		Selection:   terminal.Selection,
		Caret:       terminal.Cursor,
		Scrollbar:   bar,
	}
}

// focusedDocument is the open project's document whose text owns the hit id, and nil when
// none does.
func (a *App) focusedDocument(id ui.ID) *editorview.View {
	p := a.project
	if p == nil {
		return nil
	}
	for _, d := range p.docs.list {
		if d.view.Owns(id) {
			return d.view
		}
	}
	return nil
}

// documentPointer gives a pointer event to the open documents: the press on a text and the
// moves and the release of the selection it starts, wherever they go.
func (a *App) documentPointer(event ui.PointerEvent) (ui.EventResult, bool) {
	p := a.project
	if p == nil {
		return ui.EventResult{}, false
	}
	for _, d := range p.docs.list {
		if result, handled := d.view.Pointer(event); handled {
			return result, true
		}
	}
	return ui.EventResult{}, false
}

// drawDocumentTab declares one open file's tab: its icon, its full name, a dot while it has
// unsaved changes, and a close button. A click on the tab or its close button is recorded
// for paintTerminal to do. pos is the tab's place among size tabs, for assistive technology.
func (a *App) drawDocumentTab(f *flex.Frame, d *document, selected bool, pos, size int) {
	u := &a.term
	chip := f.Row().Height(rowHeight).Items(flex.Center).Gap(terminalChipGap).PadSides(0, 2, 0, 8).
		Shrink(0).Radius(a.theme.Metrics.RadiusItem()).
		HitWith(docTabs.At(d.id), d.name, ui.HitOptions{
			Role:     ui.RoleTab,
			Cursor:   ui.PointerCursorHand,
			Selected: selected,
			PosInSet: int32(pos + 1),
			SetSize:  int32(size),
		}).
		Pressed(flex.Look{}.Background(a.colors.Active))
	if selected {
		chip = chip.Background(a.colors.Active)
	} else {
		chip = chip.Hover(flex.Look{}.Background(a.colors.Hover))
	}
	var closeButton flex.Box
	chip.Children(func() {
		f.Icon(icons.FileCode).Size(terminalChipIcon, terminalChipIcon).Shrink(0).Color(a.colors.Subtle)
		label := f.Text(d.name).Shrink(0)
		if selected {
			label.Color(a.colors.Text)
		} else {
			label.Color(a.colors.Subtle).StateFrom(chip).Hover(flex.Look{}.Color(a.colors.Text))
		}
		if d.view.Dirty() {
			f.Row().Size(documentDirty, documentDirty).Shrink(0).Radius(documentDirty / 2).Background(a.colors.Accent)
		}
		closeButton = f.Row().Size(terminalCloseSize, terminalCloseSize).Shrink(0).Center().
			Radius(a.theme.Metrics.RadiusItem()).
			HitWith(docClose.At(d.id), a.text.Editor.CloseTab, ui.HitOptions{Role: ui.RoleButton, Cursor: ui.PointerCursorHand}).
			Hover(flex.Look{}.Background(a.colors.Hover)).Pressed(flex.Look{}.Background(a.colors.Active))
		closeButton.Children(func() {
			f.Icon(icons.X).Size(terminalCloseIcon, terminalCloseIcon).Color(a.colors.Subtle).
				StateFrom(closeButton).Hover(flex.Look{}.Color(a.colors.Text))
		})
	})
	switch {
	case closeButton.Clicked():
		u.actions = append(u.actions, tabAction{kind: actionCloseDocument, term: d.id})
	case chip.Clicked():
		u.actions = append(u.actions, tabAction{kind: actionSelectDocument, term: d.id})
	}
}
