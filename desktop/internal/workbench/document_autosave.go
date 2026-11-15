package workbench

import (
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/documentio"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/gfx"
)

// Auto-save writes a changed file a moment after typing stops, as the previous clients did
// (1.5 s on macOS). It is on by default and Settings › Editor turns it off. It never asks
// anything: a file whose disk copy conflicts, a deleted file and a hard-linked file wait for
// a save the user asks for, which can ask. Switching to another window or application saves
// every changed file at once (onFocusLost). Saving before a run and before closing goes on
// as before.

// scheduleAutoSave keeps one owned timer for the actual delay resolved by Core.
func (a *App) scheduleAutoSave(p *project, d *document) {
	if a.settings.DisableAutoSave || d.virtual || d.scratch {
		return
	}
	d.cancelAutoSave()
	generation := d.autoSave
	d.autoSaveTimer = time.AfterFunc(time.Duration(a.editorPreferences.AutoSaveDelayMilliseconds)*time.Millisecond, func() {
		a.post(func(a *App) {
			if a.project != p || d.autoSave != generation || p.docs.find(d.id) != d || a.settings.DisableAutoSave {
				return
			}
			d.autoSaveTimer = nil
			if d.view.IsComposing() {
				// An input method is still composing: try again once it may be done.
				a.scheduleAutoSave(p, d)
				return
			}
			a.saveDocumentMode(p, d.id, true)
		})
	})
}

// onFocusLost saves every changed file of the project when the window loses the keyboard,
// without waiting for the auto-save delay. A file an input method is still composing waits
// for its own auto-save.
func (a *App) onFocusLost() gfx.EventResult {
	p := a.project
	if p == nil || a.settings.DisableAutoSave {
		return gfx.EventResult{}
	}
	for _, d := range p.docs.list {
		if d.scratch || d.virtual || !d.dirty() || d.view.IsComposing() {
			continue
		}
		d.cancelAutoSave()
		a.saveDocumentMode(p, d.id, true)
	}
	return gfx.EventResult{Repaint: true}
}

// noteEditorFocus follows which file's editor has the keyboard; when the keyboard leaves it
// (for a terminal, a tool window or another file) the file is saved at once.
func (a *App) noteEditorFocus(focused gfx.ID) {
	p := a.project
	if p == nil {
		a.editorFocus = 0
		return
	}
	current := 0
	for _, d := range p.docs.list {
		if d.view.Owns(focused) {
			current = d.id
			break
		}
	}
	left := a.editorFocus
	a.editorFocus = current
	if left == 0 || left == current || a.settings.DisableAutoSave {
		return
	}
	if d := p.docs.find(left); d != nil && !d.virtual && !d.scratch && d.dirty() && !d.view.IsComposing() {
		d.cancelAutoSave()
		a.post(func(a *App) {
			if a.project == p && p.docs.find(d.id) == d {
				a.saveDocumentMode(p, d.id, true)
			}
		})
	}
}

// hardLinkSaveRequired answers a save that met a hard-linked file without the user's
// answer. Auto-save stops for the file and says so once; a save the user asked for asks
// how to write it: as a file of its own, through every link, or not at all.
func (a *App) hardLinkSaveRequired(p *project, d *document, identity string, auto bool) {
	language := a.language()
	if auto {
		if !d.linkedAutoSaveOff {
			d.linkedAutoSaveOff = true
			a.notifyInfo(i18n.SharedFormat(language, "document.fileAccess.isHardLinkedChangesAreNotSavedAutomaticallySaveManuallyToChooseHowToUpdateTheFile", map[string]string{"arg1": d.name}))
		}
		return
	}
	modes := []documentio.HardLinkMode{0, documentio.HardLinkUpdateShared, documentio.HardLinkReplacePath}
	a.prompts.queue = append(a.prompts.queue, &pluginPrompt{
		title: i18n.Shared(language, "document.fileAccess.saveAHardLinkedFile"),
		text: i18n.SharedFormat(language, "document.fileAccess.sharesItsContentsWithOtherPathsSaveAsIndependentFileUpdatesOnlyThisPathAndBreaksItsHardLinkRelationshipUpdateAllHardLinksWritesToTheSharedFileIncludingLinksOutsideThisProjectItIsNotAtomicAndAnInterruptedWriteMayLeavePartialContentsCancelKeepsYourEditsUnsaved",
			map[string]string{"arg1": d.name}),
		actions: []string{
			i18n.Shared(language, "desktop.document.hardLinkCancel"),
			i18n.Shared(language, "document.fileAccess.updateAllHardLinks"),
			i18n.Shared(language, "document.fileAccess.saveAsIndependentFile"),
		},
		onAnswer: func(choice *int) {
			if a.project != p || p.docs.find(d.id) != d {
				return
			}
			if choice == nil || *choice <= 0 || *choice >= len(modes) {
				// Cancel keeps the edits unsaved and stops what waited for the save.
				waiters := d.closeWaiters
				d.closeWaiters = nil
				for _, done := range waiters {
					done(false)
				}
				return
			}
			a.performed("editor.save.hardLink", surfaceButton)
			d.linkConsent = &documentio.HardLinkConsent{Identity: identity, Mode: modes[*choice]}
			a.saveDocument(p, d.id)
		},
	})
}

func (d *document) cancelAutoSave() {
	d.autoSave++
	if d.autoSaveTimer != nil {
		d.autoSaveTimer.Stop()
		d.autoSaveTimer = nil
	}
}
