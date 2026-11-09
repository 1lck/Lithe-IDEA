package workbench

import (
	"context"
	"errors"
	"os"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

var (
	docKeep = tree.Sub(shellPage, tree.Name("document-keep-editor"))
	docLoad = tree.Sub(shellPage, tree.Name("document-load-disk"))
)

// drawDocumentConflict places the conflict beside the affected editor, following the
// original editor notification's icon, message and link actions.
func (a *App) drawDocumentConflict(f *ui.Frame, d *document) {
	message := i18n.Shared(a.language(), "native.thisFileChangedOutsideLitheWhileYouHadUnsavedEdits")
	if d.conflictMissing {
		message = i18n.Shared(a.language(), "native.thisFileWasDeletedOutsideLitheYourEditorContentIsPreserved")
	}
	busy := d.saving || d.checking || d.checkPending || d.resolvingConflict || d.view.IsComposing()
	background, border, foreground, link, disabled := gfx.RGB24(0xFFF6E9), gfx.RGB24(0xF4CD9A), gfx.RGB24(0x000000), gfx.RGB24(0x2F5EB9), gfx.RGB24(0x9FA2A8)
	if a.colors.Dark {
		background, border, foreground, link, disabled = gfx.RGB24(0x44321D), gfx.RGB24(0x694820), gfx.RGB24(0xD1D3D9), gfx.RGB24(0x71A1FE), gfx.RGB24(0x4C4F56)
	}
	f.Column().FillWidth().Shrink(0).Background(background).Children(func() {
		f.Row().FillWidth().Height(1).Background(border)
		f.Row().FillWidth().Gap(8).PadX(12).PadY(10).Items(ui.Start).Children(func() {
			f.Icon(icons.BannerWarning).Size(16, 16).Color(gfx.RGB24(0xFFFFFF))
			f.Column().Grow(1).Gap(8).Children(func() {
				f.Paragraph(message, 3).FontSize(13).Color(foreground)
				f.Row().Gap(16).Children(func() {
					keepLabel := i18n.Shared(a.language(), "native.keepEditor")
					if d.conflictMissing {
						keepLabel = i18n.Shared(a.language(), "native.allowRecreatingFile")
					}
					if a.drawConflictLink(f, docKeep.At(d.id), keepLabel, busy, link, disabled) {
						a.keepDocumentEditor(a.project, d)
					}
					if a.drawConflictLink(f, docLoad.At(d.id), i18n.Shared(a.language(), "native.loadDiskVersion"), busy || d.conflictMissing, link, disabled) {
						a.loadDocumentDisk(a.project, d)
					}
				})
			})
		})
		f.Row().FillWidth().Height(1).Background(border)
	})
}

func (a *App) drawConflictLink(f *ui.Frame, id gfx.ID, label string, disabled bool, link, muted gfx.Color) bool {
	color := link
	if disabled {
		color = muted
	}
	button := f.Row().HitWith(id, label, gfx.HitOptions{Role: gfx.RoleButton, Cursor: gfx.PointerCursorHand, Disabled: disabled})
	button.Children(func() { f.Text(label).FontSize(13).Color(color) })
	return !disabled && button.Clicked()
}

func (a *App) conflictDecision(p *project, d *document, event core.DocumentEventType) (core.DocumentDecision, error) {
	state := core.DocumentState{Status: core.DocumentConflict, Revision: uint64(d.view.Revision()), SavedRevision: uint64(min(d.savedRevision, d.view.Revision()))}
	ctx, cancel := context.WithTimeout(p.ctx, kernelCallTimeout)
	defer cancel()
	return a.kernel.ReduceDocument(ctx, state, core.DocumentEvent{Type: event})
}

// keepDocumentEditor acknowledges exactly the observed disk version. The guarded
// writer still rejects a subsequent external change instead of forcing an overwrite.
func (a *App) keepDocumentEditor(p *project, d *document) {
	if a.project != p || p.docs.find(d.id) != d || !d.conflicted || d.saving || d.checking || d.checkPending || d.resolvingConflict || d.view.IsComposing() {
		return
	}
	decision, err := a.conflictDecision(p, d, core.DocumentKeepEditor)
	if err != nil || decision.Action != core.DocumentNoAction || decision.State.Status != core.DocumentDirty {
		a.conflictResolutionFailed(d, err)
		return
	}
	if d.conflictMissing {
		d.recreateMissing = true
	} else {
		d.view.MarkSaved(d.conflictContent.Snapshot())
		d.recreateMissing = false
	}
	a.clearDocumentConflict(d)
}

// loadDocumentDisk reads on a worker and refuses to replace an editor changed while
// the read was running. Undo restores the previous local contents if desired.
func (a *App) loadDocumentDisk(p *project, d *document) {
	if a.project != p || p.docs.find(d.id) != d || !d.conflicted || d.conflictMissing || d.saving || d.checking || d.checkPending || d.resolvingConflict || d.view.IsComposing() {
		return
	}
	decision, err := a.conflictDecision(p, d, core.DocumentLoadDisk)
	if err != nil || decision.Action != core.DocumentReloadFromDisk {
		a.conflictResolutionFailed(d, err)
		return
	}
	d.resolvingConflict = true
	revision, generation := d.view.Revision(), d.conflictGeneration
	read := a.documentReader
	a.background(p, 0, func(context.Context) func(*App) {
		data, err := read(d.path)
		var content editorview.Content
		if err == nil {
			content = editorview.Prepare(data)
		}
		return func(a *App) {
			d.resolvingConflict = false
			if p.docs.find(d.id) != d || !d.conflicted || d.conflictGeneration != generation || d.saving || d.checking || d.checkPending || d.view.Revision() != revision || d.view.IsComposing() {
				return
			}
			if err != nil {
				if errors.Is(err, os.ErrNotExist) {
					d.checkPending = true
					a.scheduleDocumentChecks(p)
				} else {
					a.conflictResolutionFailed(d, err)
				}
				return
			}
			if d.view.ResolveWithDisk(content) {
				d.recreateMissing = false
				d.savedRevision = d.view.Revision()
				a.clearDocumentConflict(d)
			}
		}
	})
}

func (a *App) conflictResolutionFailed(d *document, err error) {
	if err == nil {
		err = errors.New("unexpected document conflict lifecycle action")
	}
	a.emit(documentFailedLevel, documentEventOpenFailed, documentOpenFields(err))
	a.notify(d.name + ": " + i18n.Shared(a.language(), "desktop.document.externalReadFailed"))
}
