package workbench

// This file applies the two Commit switches of the Version Control settings (matrix id
// git-local-changelists). Hiding the ChangeLists lists the changes flat and lets every staged
// change commit together; the lists and their assignments are kept on disk, so showing them again
// restores them. Hiding the parent references option commits with the parent references updated,
// as the option would when it is on.

// setHideChangeLists stores the Commit switch that hides the ChangeLists and applies it to the
// open project at once.
func (a *App) setHideChangeLists(hide bool) {
	if a.settings.HideChangeLists == hide {
		return
	}
	a.settings.HideChangeLists = hide
	a.saveSettings()
	if p := a.project; p != nil {
		a.syncChangeListSettings(p)
	}
}

// setHideParentReferences stores the Commit switch that hides the parent references option.
func (a *App) setHideParentReferences(hide bool) {
	if a.settings.HideParentReferences == hide {
		return
	}
	a.settings.HideParentReferences = hide
	a.saveSettings()
}

// syncChangeListSettings gives p the setting that hides its ChangeLists. A hidden list drops the
// selection the batch move would act on, since the lists it moves to are not shown.
func (a *App) syncChangeListSettings(p *project) {
	hidden := a.settings.HideChangeLists
	if hidden && !p.lists.hidden {
		p.lists.selected, p.lists.anchor = nil, ""
	}
	p.lists.hidden = hidden
}
