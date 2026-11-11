package workbench

import (
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/documentio"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
)

// Auto-save writes a changed file a moment after typing stops, as the previous clients did
// (1.5 s on macOS). It is on by default and Settings › Editor turns it off. It never asks
// anything: a file whose disk copy conflicts, a deleted file and a hard-linked file wait for
// a save the user asks for, which can ask. Saving before a run and before closing goes on
// as before.

// autoSaveDelay is how long after the last edit a changed file is saved.
const autoSaveDelay = 1500 * time.Millisecond

// scheduleAutoSave saves d once no edit came for autoSaveDelay.
func (a *App) scheduleAutoSave(p *project, d *document) {
	if a.settings.DisableAutoSave || d.virtual {
		return
	}
	d.autoSave++
	generation := d.autoSave
	time.AfterFunc(autoSaveDelay, func() {
		a.post(func(a *App) {
			if a.project != p || d.autoSave != generation || p.docs.find(d.id) != d || a.settings.DisableAutoSave {
				return
			}
			if d.view.IsComposing() {
				// An input method is still composing: try again once it may be done.
				a.scheduleAutoSave(p, d)
				return
			}
			a.saveDocumentMode(p, d.id, true)
		})
	})
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
