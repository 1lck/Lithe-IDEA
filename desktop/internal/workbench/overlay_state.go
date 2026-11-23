package workbench

import (
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// overlayHost is the state of what the window shows over the workbench besides the dialogs'
// own: the toasts a notice raises.
type overlayHost struct {
	toaster      ui.Toaster
	trappedFocus bool
}

// canPresentGitResult leaves the user's current dialog or focused popup in place.
func (a *App) canPresentGitResult(p *project) bool {
	return a.project == p && a.shownTab() == a && !a.overlay.trappedFocus &&
		a.branch.dialog == branchDialogNone && p.worktrees.dialog == worktreeDialogNone
}

// drawGitRemovalPath exposes the complete path even if a narrow dialog elides some lines.
func (a *App) drawGitRemovalPath(c ui.C, path string) {
	ui.Paragraph(c, path, 3).Color(a.colors.Subtle).
		HitWith(ui.ID(c.Part("removal-path")), path, gfx.HitOptions{Role: gfx.RoleStatus}).Tooltip(path)
}
