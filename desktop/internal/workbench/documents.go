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
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/logwindow"
	"github.com/vivaui/viva/gfx"
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
	// path is the file's absolute path, name its base name, which is the tab's
	// title, and languageID the editor language a language server is selected
	// by.
	path, name string
	languageID string
	view       *editorview.View
	// conflict is the notice shown while the file changed on disk under unsaved edits.
	conflict conflictBanner
	// sync is the document's state in its language-server session.
	sync               documentSync
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
	conflictContent    editorview.Content
	conflictGeneration uint64
	resolvingConflict  bool
	// recreateMissing records the user's explicit choice to save a deleted file.
	recreateMissing bool
	// input and draw are the Control's handlers and painter, made once with the document;
	// hit is the identity and group the editor group the last paint declared it in.
	input ui.Handlers
	draw  func(*ui.DrawContext)
	hit   gfx.ID
	group string
	// virtual marks a read-only document a plugin provides for a URI that names no
	// file (a class inside a jar). path then holds the URI: the document is never
	// watched, saved or synchronized with a language server, and the host keeps no
	// copy once it closes.
	virtual bool
	// encoding is the id of the text encoding the file is read and written in; "" is plain
	// UTF-8. hasBOM says a byte order mark leads the file. diskBytes are the bytes the file
	// held when it was last read or written, kept only for a document whose bytes differ from
	// its text (see encoding.go); encodingChanged says the user chose another encoding to save
	// in, which makes an unedited document worth saving.
	encoding        string
	hasBOM          bool
	diskBytes       []byte
	encodingChanged bool
	// previousEncoding is what encodingChanged replaced, until the save succeeds.
	previousEncoding *encodingChoice
	// conflictBytes are the bytes of the disk version a conflict notice shows.
	conflictBytes []byte
}

func (d *document) dirty() bool { return d.view.Dirty() || d.recreateMissing || d.encodingChanged }

// documentLocation is where a document should place its caret once it has
// opened. line is one-based, as the editor and search results use; column is
// zero-based UTF-16, as Core and LSP report a position.
type documentLocation struct {
	line      int
	column    int
	columnSet bool
}

// documentSet is the files a project has open. The zero value has none.
type documentSet struct {
	list []*document
	next int
	// opening are the paths being read, so a second click while one is read opens nothing.
	opening map[string]bool
	// openWaiters are the callers that wait for a file being read to become a tab, or to fail.
	openWaiters map[string][]func(*document, error)
	// locations hold the latest requested position while a document opens.
	locations map[string]documentLocation
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
	kernel, _ := a.kernel.(editorKernel)
	a.background(p, 0, func(ctx context.Context) func(*App) {
		read, err := readDocumentEncoded(ctx, kernel, path)
		data := read.text
		var content editorview.Content
		var grammar *syntax.Syntax
		languageID := ""
		if err == nil {
			// The rope and the measure of the lines take time in proportion to the file, so
			// they are made here and the window thread only shows them.
			content = editorview.Prepare(data)
			if language, ok := registry.ForPath(path); ok {
				grammar = registry.Syntax(language.ID)
				languageID = language.ID
			}
		}
		return func(a *App) {
			delete(p.docs.opening, path)
			location := p.docs.locations[path]
			delete(p.docs.locations, path)
			defer a.openFinished(p, path, err)
			if err != nil {
				a.emit(documentFailedLevel, documentEventOpenFailed, documentOpenFields(err))
				a.notify(a.text.Editor.OpenFailed(name, a.documentReason(err)))
				return
			}
			a.placeDocument(p, path, name, content, grammar, languageID)
			if d := p.docs.byPath(path); d != nil {
				d.encoding, d.hasBOM, d.diskBytes = read.encoding, read.hasBOM, read.disk
			}
			// A plugin that serves this language starts its server the first time a
			// file of it is opened, not when the project opens: a workspace of Go
			// files must not pay for a Java server.
			if languageID != "" {
				a.startPluginServer(languageID)
			}
			if d := p.docs.byPath(path); d != nil {
				if location.columnSet {
					d.view.GoToNavigation(location.line-1, location.column, false)
				} else if location.line > 0 {
					d.view.GoToLine(location.line)
				}
			}
		}
	})
}

// openFileAt coalesces repeated navigation requests while the file is being read.
func (a *App) openFileAt(p *project, path string, line int) {
	if path == "" {
		return
	}
	if d := p.docs.byPath(path); d != nil {
		a.selectDocument(p, d.id)
		if line > 0 {
			d.view.GoToLine(line)
		}
		return
	}
	if p.docs.locations == nil {
		p.docs.locations = make(map[string]documentLocation)
	}
	p.docs.locations[path] = documentLocation{line: line}
	a.openFile(p, path)
}

// openFileAtPosition opens a file at a zero-based LSP line and UTF-16 column.
// A file that is already open is selected and its caret moved without reading
// it again.
func (a *App) openFileAtPosition(p *project, path string, line, column int) {
	if path == "" {
		return
	}
	a.recordNavigationJump(p, path, line, column)
	if d := p.docs.byPath(path); d != nil {
		a.selectDocument(p, d.id)
		d.view.GoToNavigation(line, column, false)
		return
	}
	if p.docs.locations == nil {
		p.docs.locations = make(map[string]documentLocation)
	}
	p.docs.locations[path] = documentLocation{line: line + 1, column: column, columnSet: true}
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
func (a *App) placeDocument(p *project, path, name string, content editorview.Content, grammar *syntax.Syntax, languageID string) {
	a.placeDocumentAs(p, path, name, content, grammar, languageID, false)
}

// placeDocumentAs is placeDocument for a file or, with virtual, for the text a plugin
// provided under a URI.
func (a *App) placeDocumentAs(p *project, path, name string, content editorview.Content, grammar *syntax.Syntax, languageID string, virtual bool) {
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
	d := &document{id: id, path: path, name: name, languageID: languageID, virtual: virtual}
	d.view = editorview.New(editorview.Config{
		Label:   name,
		Content: content,
		Syntax:  grammar,
		Notify:  a.invalidator.Invalidate,
		Save:    func() { a.saveDocument(p, id) },
		OnEdit:  func(edit editorview.Edit) { a.documentEdited(p, d, edit) },
	})
	d.view.SetReadOnly(virtual)
	a.documentInput(p, d)
	p.docs.list = append(p.docs.list, d)
	p.docs.group = group
	if !virtual {
		a.watchDocument(p, d)
	}
	a.focusDocument(id)
	if !virtual {
		a.startDocumentSync(p, d)
	}
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
	if a.semantics.documentID != 0 && a.semantics.documentID != id {
		a.closePluginSemantics()
	}
	if g.Selected != member && !a.reduceTerminals(p, p.terms.bench, core.ActivateEditor(g.ID, member)) {
		return
	}
	p.docs.group = g.ID
	a.focusDocument(id)
}

// focusDocument asks for the keyboard to go to document id as soon as it is painted.
func (a *App) focusDocument(id int) { a.focus = focusTarget{doc: id} }

// saveDocument serializes writes for a document. A repeated request is coalesced,
// and close waiters resume only after the latest editor contents are persisted.
func (a *App) saveDocument(p *project, id int) {
	d := p.docs.find(id)
	if d == nil || d.virtual {
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
	expected := d.expectedDiskBytes()
	path, name, revision := d.path, d.name, d.view.Revision()
	write := a.documentWriter
	create := a.documentCreator
	missing := d.recreateMissing
	d.saving = true
	a.background(p, 0, func(ctx context.Context) func(*App) {
		var err error
		bytesOut := data
		if bytesOut, err = a.encodeForSave(ctx, d, data); err == nil {
			if missing {
				err = create(path, bytesOut)
			} else {
				err = write(path, bytesOut, expected)
			}
		}
		return func(a *App) {
			d.saving = false
			defer a.scheduleDocumentChecks(p)
			if err != nil {
				d.saveAgain = false
				if _, unmappable := core.IsEncodingUnmappable(err); unmappable && d.encodingChanged {
					// The reason names the encoding that failed, so it is shown first.
					a.saveFailed(id, revision, name, err)
					d.revertEncodingChoice()
					waiters := d.closeWaiters
					d.closeWaiters = nil
					for _, done := range waiters {
						done(false)
					}
					return
				}
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
			d.encodingChanged, d.previousEncoding = false, nil
			if d.needsCodec() {
				d.diskBytes = bytesOut
			} else {
				d.diskBytes = nil
			}
			d.recreateMissing = false
			d.savedRevision = revision
			a.clearDocumentConflict(d)
			a.syncDocumentSaved(p, d, data)
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
	case func() bool { _, ok := core.IsEncodingUnmappable(err); return ok }():
		reason = i18n.SharedFormat(a.language(), "desktop.encoding.unmappable", map[string]string{"encoding": a.saveEncodingName(id)})
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
		a.closeDocumentInSession(p, d)
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
// with the terminal's caret and selection colors. The minimap's button is a quiet button on
// the panel's ground.
func (a *App) editorLook() editorview.Look {
	terminal := a.terminalLook()
	line := a.colors.Hover
	line.Alpha *= 0.6
	bar := a.colors.Subtle
	bar.Alpha *= 0.45
	return editorview.Look{
		Dark:         a.colors.Dark,
		Background:   a.colors.Editor,
		Foreground:   a.colors.Text,
		Subtle:       a.colors.Subtle,
		CurrentLine:  line,
		Selection:    terminal.Selection,
		Caret:        terminal.Cursor,
		Scrollbar:    bar,
		Button:       a.colors.Panel,
		ButtonHover:  a.colors.Hover,
		ButtonBorder: a.theme.Border,
	}
}

// editorMessages is the words the editors give assistive technology for their parts.
func (a *App) editorMessages() editorview.Messages {
	words := &a.text.Editor
	return editorview.Messages{
		Minimap:             words.Minimap,
		HideMinimap:         words.HideMinimap,
		ShowMinimap:         words.ShowMinimap,
		VerticalScrollbar:   words.VerticalScrollbar,
		HorizontalScrollbar: words.HorizontalScrollbar,
	}
}

// toggleMinimap hides the minimap of every editor, or shows it again, for a click on the button
// beside it. The choice is written to the settings once the paint is over, as writing a file
// must not hold up the frame.
func (a *App) toggleMinimap(canvas *gfx.Canvas) {
	a.settings.HideMinimap = !a.settings.HideMinimap
	canvas.AfterPaint(a.saveSettings)
}

// focusedDocument is the open project's document whose text owns the hit id, and nil when
// none does.
func (a *App) focusedDocument(id gfx.ID) *editorview.View {
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
