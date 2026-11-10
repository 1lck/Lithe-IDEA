package workbench

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/ui"
)

var (
	renameDialogScope   = tree.ID(shellPage, "rename-dialog")
	renameDialogCancel  = tree.ID(shellPage, "rename-dialog-cancel")
	renameDialogClose   = tree.ID(shellPage, "rename-dialog-close")
	renameDialogConfirm = tree.ID(shellPage, "rename-dialog-confirm")
	renameNameField     = tree.ID(shellPage, "rename-name")
)

const renameDialogWidth = 420

// drawRenameDialog is the thin view over renameState: it shows the name field
// and reports confirm or cancel to the rename logic.
func (a *App) drawRenameDialog(f *ui.Frame) {
	state := &a.semantics.rename
	if !state.open {
		return
	}
	language := a.language()
	d := f.Dialog(ui.DialogSpec{
		Title:          i18n.Shared(language, "desktop.semantics.renameTitle"),
		Description:    i18n.Shared(language, "desktop.semantics.renameDescription"),
		Width:          renameDialogWidth,
		Scope:          renameDialogScope,
		DismissID:      renameDialogCancel,
		CloseID:        renameDialogClose,
		InitialFocusID: renameNameField,
	})
	submitted := false
	d.Body(func() {
		label := i18n.Shared(language, "desktop.semantics.renameName")
		submitted = f.Field(&state.name, renameNameField, label, label).FillWidth().Disabled(state.busy).Submitted()
	})
	cancelled, confirmed := false, false
	d.Footer(func() {
		cancelled = f.Button(renameDialogCancel, i18n.Shared(language, "desktop.semantics.renameCancel")).Outline().Clicked()
		confirmed = f.Button(renameDialogConfirm, i18n.Shared(language, "desktop.semantics.renameButton")).Disabled(!a.renameReady()).Clicked()
	})
	switch {
	case cancelled, d.Dismissed():
		a.cancelPluginRename()
	case confirmed || submitted:
		a.confirmPluginRename()
	}
}
