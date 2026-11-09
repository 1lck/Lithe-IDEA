package workbench

import (
	"context"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/documentio"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/syntax"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
	"github.com/1lck/Lithe-IDEA/desktop/internal/fileicons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/logwindow"
	"github.com/vivaui/viva/flex"
	"github.com/vivaui/viva/ui"
)

const (
	// documentMemberPrefix starts the member name of an open file in a tab group: "file:3".
	documentMemberPrefix = "file:"
	// documentDirty is the side of the dot a tab shows while its file has unsaved changes.
	documentDirty = 6

	// The log events of a file that could not be opened or saved, the level the kernel's event
	// catalog declares for both, and the stage a save fails at. The log store drops an event
	// whose level or fields differ from its declaration.
	documentEventOpenFailed = "editor.document.open_failed"
	documentEventSaveFailed = "editor.document.save_failed"
	documentFailedLevel     = core.LevelError
	documentSaveStage       = "write"
)

// The identities of the open files' controls. Each is a scope whose At(n) is the control of
// the document with id n: docTabs its tab, docClose its tab's close button, docViews its
// text, which holds the keyboard focus, and docWrap the soft wrap switch at the end of the
// strip of the group that shows it.
var (
	docTabs  = tree.Sub(shellPage, tree.Name("document-tabs"))
	docClose = tree.Sub(shellPage, tree.Name("document-close"))
	docViews = tree.Sub(shellPage, tree.Name("document-views"))
	docWrap  = tree.Sub(shellPage, tree.Name("document-soft-wrap"))
)

// These errors explain why a file cannot be opened, besides the system's errors.
var (
	errNotText             = errors.New("not a text file")
	errUnsupportedEncoding = errors.New("unsupported text encoding")
	errTooLarge            = documentio.ErrTooLarge
	errComposing           = errors.New("input method composition is active")
)

// document is a file open in a tab of the editor area.
type document struct {
	// id identifies the document for as long as the project is open; it is never reused.
	id int
	// path is the file's absolute path, and name its base name, which is the tab's title.
	path, name         string
	view               *editorview.View
	saving             bool
	saveAgain          bool
	closeWaiters       []func(bool)
	checkWaiters       []func(bool)
	checkFailed        bool
	savedRevision      int
	checkPending       bool
	checking           bool
	conflicted         bool
	conflictMissing    bool
	conflictContent    editorview.ReloadContent
	conflictGeneration uint64
	resolvingConflict  bool
	// recreateMissing records the user's explicit choice to save a deleted file.
	recreateMissing bool
}

func (d *document) dirty() bool { return d.view.Dirty() || d.recreateMissing }

// documentSet is the files a project has open. The zero value has none.
type documentSet struct {
	list []*document
	next int
	// opening are the paths being read, so a second click while one is read opens nothing.
	opening map[string]bool
	// locations hold the latest requested one-based line while a document opens.
	locations map[string]int
	// group is the editor group a document was last shown or focused in, where the next file
	// opens while it is still there.
	group    string
	watches  map[string]*documentWatch
	checking int
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
			line := p.docs.locations[path]
			delete(p.docs.locations, path)
			if err != nil {
				a.emit(documentFailedLevel, documentEventOpenFailed, documentOpenFields(err))
				a.notify(a.text.Editor.OpenFailed(name, a.documentReason(err)))
				return
			}
			a.placeDocument(p, path, name, data, grammar)
			if d := p.docs.byPath(path); d != nil && line > 0 {
				d.view.GoToLine(line)
			}
		}
	})
}

// openFileAt coalesces repeated navigation requests while the file is being read.
func (a *App) openFileAt(p *project, path string, line int) {
	if d := p.docs.byPath(path); d != nil {
		a.selectDocument(p, d.id)
		if line > 0 {
			d.view.GoToLine(line)
		}
		return
	}
	if p.docs.locations == nil {
		p.docs.locations = make(map[string]int)
	}
	p.docs.locations[path] = line
	a.openFile(p, path)
}

// readDocument reads an editor file and asks Core to classify its complete
// contents, refusing binary controls or bytes that cannot be edited as UTF-8.
func readDocument(path string) ([]byte, error) {
	data, err := documentio.ReadFile(path)
	if err != nil {
		return nil, err
	}
	kind, err := core.ClassifyDocumentText(data)
	if err != nil {
		return nil, err
	}
	switch kind {
	case core.DocumentInvalidUTF8:
		return nil, errUnsupportedEncoding
	case core.DocumentBinary:
		return nil, errNotText
	}
	return data, nil
}

// documentOpenFields are the fields of editor.document.open_failed: the error, and the
// catalog's token for why the file was not opened.
func documentOpenFields(err error) map[string]any {
	fields := logwindow.ErrorFields(documentLogError(err))
	fields["reason"] = documentOpenReason(err)
	return fields
}

// documentLogError removes filesystem path wrappers before an error enters a log.
// Joined failures retain their underlying errors, including any cleanup failure.
func documentLogError(err error) error {
	switch e := err.(type) {
	case *os.PathError:
		return documentLogError(e.Err)
	case *os.LinkError:
		return documentLogError(e.Err)
	case interface{ Unwrap() []error }:
		parts := e.Unwrap()
		clean := make([]error, 0, len(parts))
		for _, part := range parts {
			if part != nil {
				clean = append(clean, documentLogError(part))
			}
		}
		if len(clean) > 0 {
			return errors.Join(clean...)
		}
	case interface{ Unwrap() error }:
		if cause := e.Unwrap(); cause != nil {
			return documentLogError(cause)
		}
	}
	return err
}

// documentOpenReason is the token for why a file could not be opened.
func documentOpenReason(err error) string {
	switch {
	case errors.Is(err, errNotText):
		return "not_text"
	case errors.Is(err, errUnsupportedEncoding):
		return "unsupported_encoding"
	case errors.Is(err, errTooLarge):
		return "too_large"
	case errors.Is(err, documentio.ErrNotRegular):
		return "not_regular"
	case errors.Is(err, documentio.ErrSymbolicLink):
		return "symbolic_link"
	case errors.Is(err, fs.ErrNotExist):
		return "not_found"
	case errors.Is(err, fs.ErrPermission):
		return "permission_denied"
	}
	return "read_failed"
}

// documentReason is the words for why a file could not be opened or saved: the editor's own
// reasons in the current language, and the system's message for the others.
func (a *App) documentReason(err error) string {
	switch {
	case errors.Is(err, errNotText):
		return a.text.Editor.NotText
	case errors.Is(err, errUnsupportedEncoding):
		return i18n.Shared(a.language(), "desktop.editor.unsupportedEncoding")
	case errors.Is(err, errTooLarge):
		return a.text.Editor.TooLarge
	case errors.Is(err, documentio.ErrNotRegular):
		return i18n.Shared(a.language(), "document.fileAccess.onlyRegularFilesCanBeOpenedAsTextDevicesSocketsAndNamedPipesAreNotSupported")
	case errors.Is(err, documentio.ErrSymbolicLink):
		return i18n.Shared(a.language(), "document.fileAccess.openTheTargetFileDirectlySymbolicLinkEditingIsNotSupportedByThisFileAdapter")
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
	a.watchDocument(p, d)
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

// saveDocument serializes writes for a document. A repeated request is coalesced,
// and close waiters resume only after the latest editor contents are persisted.
func (a *App) saveDocument(p *project, id int) {
	d := p.docs.find(id)
	if d == nil {
		return
	}
	if d.view.IsComposing() {
		a.saveFailed(id, d.view.Revision(), d.name, errComposing)
		return
	}
	if d.saving {
		d.saveAgain = true
		return
	}
	if !d.dirty() {
		return
	}
	data, text := d.view.Text()
	expected := d.view.SavedBytes()
	path, name, revision := d.path, d.name, d.view.Revision()
	write := a.documentWriter
	create := a.documentCreator
	missing := d.recreateMissing
	d.saving = true
	a.background(p, 0, func(context.Context) func(*App) {
		var err error
		if missing {
			err = create(path, data)
		} else {
			err = write(path, data, expected)
		}
		return func(a *App) {
			d.saving = false
			defer a.scheduleDocumentChecks(p)
			if err != nil {
				d.saveAgain = false
				if errors.Is(err, documentio.ErrConflict) {
					d.checkPending = true
				}
				a.saveFailed(id, revision, name, err)
				waiters := d.closeWaiters
				d.closeWaiters = nil
				for _, done := range waiters {
					done(false)
				}
				return
			}
			d.view.MarkSaved(text)
			d.recreateMissing = false
			d.savedRevision = revision
			a.clearDocumentConflict(d)
			if d.view.IsComposing() && len(d.closeWaiters) > 0 {
				a.saveFailed(id, d.view.Revision(), name, errComposing)
				waiters := d.closeWaiters
				d.closeWaiters = nil
				d.saveAgain = false
				for _, done := range waiters {
					done(false)
				}
				return
			}
			if (d.saveAgain || len(d.closeWaiters) > 0) && d.dirty() {
				d.saveAgain = false
				a.saveDocument(p, id)
				return
			}
			d.saveAgain = false
			waiters := d.closeWaiters
			d.closeWaiters = nil
			for _, done := range waiters {
				done(true)
			}
		}
	})
}

// saveBeforeClose waits asynchronously for any in-flight save and the latest edits.
func (a *App) saveBeforeClose(p *project, d *document, done func(bool)) {
	if d.view.IsComposing() {
		a.saveFailed(d.id, d.view.Revision(), d.name, errComposing)
		done(false)
		return
	}
	if !d.saving && !d.dirty() {
		a.checkBeforeClose(p, d, done)
		return
	}
	d.closeWaiters = append(d.closeWaiters, func(ok bool) {
		if !ok {
			done(false)
			return
		}
		a.checkBeforeClose(p, d, done)
	})
	if !d.saving {
		a.saveDocument(p, d.id)
	}
}

// checkBeforeClose makes a fresh bounded disk check even if the watcher has not
// yet delivered an external deletion. Waiters run only after queued checks settle.
func (a *App) checkBeforeClose(p *project, d *document, done func(bool)) {
	d.checkWaiters = append(d.checkWaiters, done)
	d.checkPending = true
	a.scheduleDocumentChecks(p)
}

// saveFailed logs that document id could not be saved at revision and shows that the file
// name was not saved.
func (a *App) saveFailed(id, revision int, name string, err error) {
	a.emit(documentFailedLevel, documentEventSaveFailed, documentSaveFields(id, revision, err))
	reason := a.documentReason(err)
	switch {
	case errors.Is(err, errComposing):
		reason = i18n.Shared(a.language(), "editor.completeInputBeforeSaving")
	case errors.Is(err, documentio.ErrTooLarge):
		reason = i18n.Shared(a.language(), "editor.fileTooLargeToSave")
	case errors.Is(err, documentio.ErrUnsupported):
		reason = i18n.Shared(a.language(), "editor.guardedSaveUnavailable")
	case errors.Is(err, documentio.ErrNotRegular):
		reason = i18n.Shared(a.language(), "document.fileAccess.onlyRegularFilesCanBeOpenedAsTextDevicesSocketsAndNamedPipesAreNotSupported")
	case errors.Is(err, documentio.ErrConflict):
		reason = i18n.Shared(a.language(), "editor.externalConflict")
	case errors.Is(err, documentio.ErrHardLink):
		reason = i18n.Shared(a.language(), "editor.hardLinkSaveUnavailable")
	case errors.Is(err, documentio.ErrSymbolicLink):
		reason = i18n.Shared(a.language(), "document.fileAccess.openTheTargetFileDirectlySymbolicLinkEditingIsNotSupportedByThisFileAdapter")
	}
	a.notify(a.text.Editor.SaveFailed(name, reason))
}

// documentSaveFields are the fields of editor.document.save_failed for document id, whose
// text was at revision when it was written.
func documentSaveFields(id, revision int, err error) map[string]any {
	fields := logwindow.ErrorFields(documentLogError(err))
	fields["document"] = strconv.Itoa(id)
	fields["revision"] = revision
	fields["stage"] = documentSaveStage
	return fields
}

// closeDocument keeps the tab and its contents alive until its last save succeeds.
func (a *App) closeDocument(p *project, id int) {
	d := p.docs.find(id)
	if d == nil {
		return
	}
	a.saveBeforeClose(p, d, func(ok bool) {
		if !ok || a.project != p || p.docs.find(id) != d {
			return
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
		a.unwatchDocument(p, d)
		if next := p.selectedDocument(group); next != nil {
			a.focusDocument(next.id)
		} else if term := p.terms.selected(group); term != nil {
			a.focusTerminal(term.id)
		}
	})
}

// saveProjectDocuments drains writes and verifies each current document before closing.
func (a *App) saveProjectDocuments(p *project, done func(bool)) {
	a.saveProjectPass(p, make(map[int]int), done)
}

func (a *App) saveProjectPass(p *project, verified map[int]int, done func(bool)) {
	for _, d := range p.docs.list {
		if d.saving {
			a.saveBeforeClose(p, d, func(ok bool) {
				if !ok {
					done(false)
					return
				}
				verified[d.id] = d.view.Revision()
				a.saveProjectPass(p, verified, done)
			})
			return
		}
	}
	documents := make([]core.SaveBatchDocument, 0, len(p.docs.list))
	for _, d := range p.docs.list {
		documents = append(documents, core.SaveBatchDocument{ID: documentMember(d.id), Dirty: d.dirty() || d.conflicted, ContentSynchronized: !d.view.IsComposing()})
	}
	ctx, cancel := context.WithTimeout(p.ctx, kernelCallTimeout)
	plan, err := a.kernel.PlanDocumentSaveBatch(ctx, documents)
	cancel()
	if err != nil {
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("document_save_batch", err))
		a.notify(a.text.Errors.Core(err.Error()))
		done(false)
		return
	}
	var d *document
	if len(plan.Members) > 0 {
		id, valid := memberDocument(plan.Members[0])
		d = p.docs.find(id)
		if !valid || d == nil {
			done(false)
			return
		}
	} else {
		for _, candidate := range p.docs.list {
			if revision, ok := verified[candidate.id]; !ok || revision != candidate.view.Revision() || candidate.checkPending || candidate.checking {
				d = candidate
				break
			}
		}
		if d == nil {
			ctx, cancel := context.WithTimeout(p.ctx, kernelCallTimeout)
			decision, err := a.kernel.ReduceDocumentSaveBatch(ctx, plan.Members, nil, documents)
			cancel()
			if err != nil {
				a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("document_save_batch", err))
				a.notify(a.text.Errors.Core(err.Error()))
				done(false)
				return
			}
			done(decision.Status == core.SaveBatchSaved)
			return
		}
	}
	a.saveBeforeClose(p, d, func(ok bool) {
		if !ok {
			done(false)
			return
		}
		verified[d.id] = d.view.Revision()
		a.saveProjectPass(p, verified, done)
	})
}

// closeDocuments releases views after their saves have completed.
func (a *App) closeDocuments(p *project) {
	for _, watch := range p.docs.watches {
		watch.close()
	}
	for _, d := range p.docs.list {
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
		f.Icon(fileicons.ForFile(d.name, a.colors.Dark)).Size(terminalChipIcon, terminalChipIcon).Shrink(0).Color(a.colors.Subtle)
		label := f.Text(d.name).Shrink(0)
		if selected {
			label.Color(a.colors.Text)
		} else {
			label.Color(a.colors.Subtle).StateFrom(chip).Hover(flex.Look{}.Color(a.colors.Text))
		}
		if d.dirty() {
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
