package workbench

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// The branch button of the title bar and the menu rows of the welcome page are still
// declared with the Frame, because the title bar and the welcome page are not Pages yet. The
// popup the button opens and its dialogs are a Page (branch_view.go).

// drawChromeBranch declares the checked-out branch as the button that opens the branch
// popup, and shows nothing when the project is not a repository. It returns the button,
// whether it is shown, and whether it was clicked. The button is kept in a.branch.button,
// which the popup of the overlay page is placed under once the frame is laid out.
func (a *App) drawChromeBranch(f *ui.Frame) (shown, clicked bool) {
	name := a.project.git.branch()
	if name == "" {
		return false, false
	}
	open := a.branch.open
	button := f.Row().Height(chromeIconButton).Shrink(0).Items(ui.Center).Gap(chromeGap).PadX(chromeEdge).
		Radius(a.theme.Metrics.RadiusItem()).
		HitWith(chromeBranchButton, a.text.Title.BranchMenu, gfx.HitOptions{
			Role:       gfx.RoleButton,
			Cursor:     gfx.PointerCursorHand,
			Value:      name,
			Expandable: true,
			Expanded:   open,
		}).
		Pressed(ui.Look{}.Background(a.colors.Active))
	if open {
		button = button.Background(a.colors.Active)
	} else {
		button = button.Hover(ui.Look{}.Background(a.colors.Hover))
	}
	button.Children(func() {
		f.Icon(icons.GitBranch).Size(chromeIconSize, chromeIconSize).Color(a.colors.Subtle)
		f.Text(name).Color(a.colors.Subtle).LineHeight(chromeLineHeight).Ellipsis().MaxWidth(chromeBranchMax)
		f.Icon(icons.ChevronDown).Size(chromeMarkSize, chromeMarkSize).Color(a.colors.Subtle)
	})
	a.branch.button = button
	return true, button.Clicked()
}

// drawBranchMenuItem declares one item of the welcome page's menus and reports a click on it.
func (a *App) drawBranchMenuItem(f *ui.Frame, id gfx.ID, label string) bool {
	row := a.chromeHover(f.Row().Height(chromeMenuRow).Shrink(0).FillWidth().Items(ui.Center).PadX(chromeEdge).
		Radius(a.theme.Metrics.RadiusItem()).
		HitWith(id, label, gfx.HitOptions{Role: gfx.RoleMenuItem, Cursor: gfx.PointerCursorHand}))
	row.Children(func() {
		f.Text(label).Color(a.colors.Text).LineHeight(chromeLineHeight).Ellipsis()
	})
	return row.Clicked()
}
