package workbench

import (
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/fileicons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// statusCrumbIcon is the size of the icon of the project and of the item the path names.
const statusCrumbIcon = 14

// statusPathView declares the navigation path at the leading end of the status bar. It shows the
// project, then each folder down to the item the path names (status_path.go), with a chevron
// between each two. As in IntelliJ IDEA's navigation bar, the project and the item carry their
// icons. A document outside the project shows only its own name and icon. The path takes the
// room the readouts at the trailing end leave, and a name short of room ends in an ellipsis.
func (a *App) statusPathView(c ui.C) {
	p := a.project
	a.noteStatusPathFocus(p, c.Canvas().Focused())
	crumbs := a.statusPathCrumbs(p)
	value := a.statusPathValue(p.name, crumbs)
	k := c.Part("path")
	ui.Row(k).Grow(1).Shrink(1).MinWidth(0).Height(chromeStatusItem).Items(ui.Center).Gap(chromeGap).Clip().
		HitWith(ui.ID(k), a.text.Status.Path, gfx.HitOptions{Role: gfx.RoleStatus, Value: value, SkipFocus: true}).
		Children(func() {
			if crumbs.name != "" {
				a.statusCrumbIcon(k, fileicons.ForFile(crumbs.name, a.colors.Dark))
				a.statusCrumbName(k, crumbs.name)
				return
			}
			a.statusCrumbIcon(k, fileicons.ForDirectoryMark(fileicons.MarkModule, a.colors.Dark))
			a.statusCrumbName(k, p.name)
			for rest := crumbs.rel; rest != ""; {
				name, after, folder := strings.Cut(rest, "/")
				rest = after
				ui.Icon(c, icons.ChevronRight).Size(chromeMarkSize, chromeMarkSize).Shrink(0).Color(a.colors.Subtle)
				switch {
				case folder:
				case crumbs.dir:
					a.statusCrumbIcon(k, fileicons.ForDirectory(name, a.colors.Dark))
				default:
					a.statusCrumbIcon(k, fileicons.ForFile(name, a.colors.Dark))
				}
				a.statusCrumbName(k, name)
			}
		})
}

// statusCrumbIcon declares the icon of a crumb of the path.
func (a *App) statusCrumbIcon(c ui.C, icon gfx.Icon) {
	ui.Icon(c, icon).Size(statusCrumbIcon, statusCrumbIcon).Shrink(0)
}

// statusCrumbName declares the name of a crumb of the path.
func (a *App) statusCrumbName(c ui.C, name string) {
	ui.Text(c, name).Ellipsis().FontSize(a.theme.Metrics.FontSizeS).LineHeight(chromeLineHeight).Color(a.colors.Subtle)
}
