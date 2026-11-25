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

// conflictBanner is a document's conflict notice. Its state is the document's own flags; the
// notice is declared where the group shows the file (see documentConflict).
type conflictBanner struct{}

// The sizes of the notice: the rules above and below, the padding, the gap between the message
// and its actions, and the height of a line of text.
const (
	conflictRules   = 2
	conflictPadY    = 10
	conflictGap     = 8
	conflictLine    = 18
	conflictPadX    = 12
	conflictIcon    = 16
	conflictMaxRows = 3
)

// conflictMessage is what the notice says about d.
func (a *App) conflictMessage(d *document) string {
	if d.conflictMissing {
		return i18n.Shared(a.language(), "native.thisFileWasDeletedOutsideLitheYourEditorContentIsPreserved")
	}
	return i18n.Shared(a.language(), "native.thisFileChangedOutsideLitheWhileYouHadUnsavedEdits")
}

// documentConflict declares the notice for d: a warning icon, the message and the two ways
// out: keep the editor's text, or load the disk's version / discard a deleted document.
func (a *App) documentConflict(c ui.C, d *document) {
	busy := d.saving || d.checking || d.checkPending || d.resolvingConflict || d.view.IsComposing()
	background, border, foreground := gfx.RGB24(0xFFF6E9), gfx.RGB24(0xF4CD9A), gfx.RGB24(0x000000)
	if a.colors.Dark {
		background, border, foreground = gfx.RGB24(0x44321D), gfx.RGB24(0x694820), gfx.RGB24(0xD1D3D9)
	}
	keepLabel := i18n.Shared(a.language(), "native.keepEditor")
	if d.conflictMissing {
		keepLabel = i18n.Shared(a.language(), "native.allowRecreatingFile")
	}
	ui.Column(c).FillWidth().Shrink(0).Background(background).Children(func() {
		ui.Row(c.Part("top")).FillWidth().Height(1).Shrink(0).Background(border)
		ui.Row(c).FillWidth().Gap(conflictGap).PadX(conflictPadX).PadY(conflictPadY).Items(ui.Start).Children(func() {
			ui.Icon(c, icons.BannerWarning).Size(conflictIcon, conflictIcon).Shrink(0).Color(gfx.RGB24(0xFFFFFF))
			ui.Column(c.Part("body")).Grow(1).Shrink(1).Gap(conflictGap).Children(func() {
				ui.Paragraph(c, a.conflictMessage(d), conflictMaxRows).FontSize(13).Color(foreground)
				ui.Row(c.Part("actions")).Gap(16).Children(func() {
					if ui.Button(c.Key("keep"), keepLabel).Link().Disabled(busy).Clicked() {
						c.After(func() { a.keepDocumentEditor(a.project, d) })
					}
					if d.conflictMissing {
						if ui.Button(c.Key("discard"), i18n.Shared(a.language(), "desktop.document.discardAndClose")).Link().Disabled(busy).Clicked() {
							c.After(func() {
								a.performed("document.discardDeleted", surfaceButton)
								a.discardDeletedDocument(a.project, d)
							})
						}
					} else if ui.Button(c.Key("load"), i18n.Shared(a.language(), "native.loadDiskVersion")).Link().Disabled(busy).Clicked() {
						c.After(func() { a.loadDocumentDisk(a.project, d) })
					}
				})
			})
		})
		ui.Row(c.Part("bottom")).FillWidth().Height(1).Shrink(0).Background(border)
	})
}

// discardDeletedDocument closes the preserved editor only after the user explicitly
// discards it. Neither the missing path nor a replacement that appeared is written.
func (a *App) discardDeletedDocument(p *project, d *document) {
	if p == nil || a.project != p || p.docs.find(d.id) != d || !d.conflicted || !d.conflictMissing || d.saving || d.checking || d.checkPending || d.resolvingConflict || d.view.IsComposing() {
		return
	}
	a.recordLocalHistory(p, d.path, "unsavedDiscard", historyTexts{bufferText: d.view.TextSnapshot()})
	a.removeDocument(p, d)
	if p.docs.find(d.id) == nil {
		// removeDocument normally preserves unsaved text for recovery; explicit discard
		// must remove that checkpoint after the tab has actually closed.
		a.flushCheckpoint(p, d, true)
	}
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
		if d.needsCodec() {
			d.diskBytes = d.conflictBytes
		}
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
	read, raw := a.documentTextOf(p), a.documentRawOf(p)
	kernel, _ := a.kernel.(editorKernel)
	encoding, hasBOM, coded := d.encoding, d.hasBOM, d.needsCodec()
	// The view's text is unchanged until the apply below, which checks the revision: the content
	// is measured against it on the worker.
	base := d.view.TextSnapshot()
	var observed, diskText []byte
	a.background(p, 0, func(ctx context.Context) func(*App) {
		var data []byte
		var err error
		if coded {
			data, err = raw(ctx, d.path)
		} else {
			data, err = read(ctx, d.path)
		}
		observed = data
		var content editorview.Content
		if err == nil {
			var text []byte
			if text, err = decodeExternal(ctx, kernel, data, encoding, hasBOM, coded); err == nil {
				content = editorview.PrepareAgainst(base, text)
				diskText = text
			}
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
			buffer := d.view.TextSnapshot()
			if d.view.ResolveWithDisk(content) {
				a.recordLocalHistory(p, d.path, "unsavedDiscard", historyTexts{bufferText: buffer})
				a.recordLocalHistory(p, d.path, "externalChange", historyTexts{after: diskText})
				if d.needsCodec() {
					d.diskBytes = observed
				}
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
	a.notifyError(d.name + ": " + i18n.Shared(a.language(), "desktop.document.externalReadFailed"))
}
