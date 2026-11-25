package workbench

import (
	"strings"
	"unicode/utf8"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/fileicons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/treelist"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// The view of the Build tool window (build_tree.go): its header buttons, the filter and the
// tree of every build system. What a task or a run prints shows in the Run window's build
// console (build_view.go), which an action here brings forward.

// buildToolActions declares the Build window's header buttons: run what is chosen, stop the
// running build operation, detect the build systems again, open and close every group, and open
// the Build options of the project. The run waits for a task or a runnable target to be chosen;
// folding waits for the filter to be cleared, because a filter shows every match open.
func (a *App) buildToolActions(c ui.C, p *project) {
	b, t, language := &p.build, a.text.Build, a.language()
	ui.Row(c).Shrink(0).Items(ui.Center).Gap(2).Children(func() {
		label, run, ok := a.buildChosenAction(p)
		if !ok {
			label = t.ChooseTask
		}
		if _, hit := a.toolIconButton(c.Part("run"), label, icons.Play, false, !ok || b.taskID != "" && b.operation != nil); hit {
			c.After(func() {
				a.performed("build.runChosen", surfaceButton)
				run()
				a.showBuildConsole(p)
			})
		}
		if _, hit := a.toolIconButton(c.Part("stop"), runStopLabel(language, b.latest()), icons.Square, false, !b.active()); hit {
			c.After(func() {
				a.performed("build.stop", surfaceButton)
				a.stopBuildOperation(p)
			})
		}
		if _, hit := a.toolIconButton(c.Part("reload"), t.Refresh, icons.RefreshCw, false, b.loading || b.operation != nil); hit {
			c.After(func() {
				a.performed("build.systems.reload", surfaceButton)
				a.reloadBuildSystems(p)
			})
		}
		foldable := len(b.instances) != 0 && p.buildFilterQuery() == ""
		if _, hit := a.toolIconButton(c.Part("expand"), i18n.Shared(language, "outline.expandAll"), icons.ChevronsUpDown, false, !foldable); hit {
			c.After(func() {
				a.performed("build.expandAll", surfaceButton)
				p.setAllBuildGroups(true)
			})
		}
		if _, hit := a.toolIconButton(c.Part("collapse"), i18n.Shared(language, "outline.collapseAll"), icons.ChevronsDownUp, false, !foldable); hit {
			c.After(func() {
				a.performed("build.collapseAll", surfaceButton)
				p.setAllBuildGroups(false)
			})
		}
		a.buildToolbarToggles(c, p)
		if _, hit := a.toolIconButton(c.Part("options"), i18n.Shared(language, "desktop.build.ignoredPaths"), icons.Settings, false, false); hit {
			c.After(func() {
				a.performed("build.options.open", surfaceButton)
				a.openBuildOptions(p, nil)
			})
		}
	})
}

// buildToolView declares the Build tool window: the run configurations, and under them the
// tree of the build systems under a filter field, or why there is none. The configurations show
// whatever detection found, so the built-in script and program runs stay reachable in a project
// without a build system or while detection fails. The models of the groups the tree shows open
// are loaded after it is declared, a few at a time.
func (a *App) buildToolView(c ui.C, p *project) {
	b := &p.build
	if !b.loaded && !b.loading {
		a.loadBuildSystems(p)
	}
	ui.Column(c).Fill().Children(func() {
		a.runConfigList(c, p)
		// The filter field and the tree, or the notice that stands for them, are one pane, the
		// second of the splitter under the run configurations, so the splitter's limits count
		// the whole tree and not the field alone.
		ui.Column(c).FillWidth().Grow(1).Shrink(1).MinHeight(0).Children(func() {
			a.buildSystemsPane(c, p)
		})
	})
	if b.loaded && b.failed == "" && len(b.instances) > 0 {
		a.loadOpenBuildModels(p)
	}
}

// buildSystemsPane declares the build systems' part of the Build window: the filter field and
// the tree, or why there is none.
func (a *App) buildSystemsPane(c ui.C, p *project) {
	b, t, language := &p.build, a.text.Build, a.language()
	switch {
	case b.loading || !b.loaded:
		a.buildNotice(c, t.LoadingModel, "", func() {
			ui.Spinner(c).Size(16, 16)
		})
		return
	case b.failed != "":
		a.buildNotice(c, b.failed, "", func() {
			if ui.Button(c, i18n.Shared(language, "ui.retry")).Outline().Small().Clicked() {
				c.After(func() {
					a.performed("build.systems.retry", surfaceButton)
					a.reloadBuildSystems(p)
				})
			}
		})
		return
	case len(b.instances) == 0:
		a.buildNotice(c, t.NoBuildSystems, "", func() {
			if ui.Button(c, t.Refresh).Outline().Small().Clicked() {
				c.After(func() {
					a.performed("build.systems.reload", surfaceButton)
					a.reloadBuildSystems(p)
				})
			}
		})
		return
	}
	a.buildFilter(c, p)
	// The rows are listed after the filter field took this frame's typing, so the tree
	// already shows what was typed.
	rows, pending := a.buildTreeRows(p)
	if len(rows) == 0 {
		// A filter whose trees are still being laid out shows nothing rather than no match.
		if !pending {
			a.buildNotice(c, i18n.Shared(language, "desktop.build.noMatches"), "", nil)
		}
		return
	}
	list := &p.panels.choices
	// Groups and folders open and close by a click, so none of them is a pinned header.
	list.Header = nil
	list.Label = func(i int) string {
		if i >= 0 && i < len(rows) {
			return rows[i].label
		}
		return ""
	}
	ui.List(c, list, len(rows), func(row ui.ListRow) {
		a.buildTreeRow(row, p, rows[row.Index])
	}).Scrollbars().Label(t.Systems).FillWidth().Grow(1).MinHeight(0).PadY(treelist.PadY)
}

// buildFilter declares the field that narrows the tree to the build systems, projects,
// targets, tasks and tests whose name or detail holds what is typed.
func (a *App) buildFilter(c ui.C, p *project) {
	language := a.language()
	label := i18n.Shared(language, "desktop.build.filter")
	ui.Row(c).FillWidth().Shrink(0).Items(ui.Center).Gap(8).PadSides(6, 8, 4, 8).Children(func() {
		field := ui.TextField(c, &p.panels.buildFilter, label, label).Icon(icons.Search).Grow(1).MinWidth(0)
		if p.panels.buildFilter != "" {
			field = field.Action(icons.X, i18n.Shared(language, "native.clearSearch"))
			if field.ActionClicked() {
				c.After(func() {
					a.performed("build.filter.clear", surfaceButton)
					p.panels.buildFilter = ""
				})
			}
		}
	})
}

// buildNotice declares the centered message that stands in for the tree: the Build icon, the
// message, an optional hint below it and an optional action below that.
func (a *App) buildNotice(c ui.C, message, hint string, action func()) {
	ui.Column(c).Fill().Center().Gap(8).PadX(shellContentPad).Children(func() {
		ui.Icon(c, icons.Wrench).Size(28, 28).Shrink(0).Color(a.colors.Subtle).Opacity(0.6)
		ui.Paragraph(c, message, 3).FillWidth().TextCenter().Color(a.colors.Text)
		if hint != "" {
			ui.Paragraph(c, hint, 4).FillWidth().TextCenter().FontSize(treeFontSize - 1).Color(a.colors.Subtle)
		}
		if action != nil {
			action()
		}
	})
}

// buildTreeRow declares one row of the build tree by its kind.
func (a *App) buildTreeRow(row ui.ListRow, p *project, spec buildRow) {
	instance := &p.build.instances[spec.instance]
	switch spec.kind {
	case buildRowGroup:
		a.buildGroupRow(row, p, instance, spec)
	case buildRowFolder:
		a.buildFolderRow(row, p, instance, spec)
	case buildRowEmpty:
		if spec.tests {
			a.buildTestStatusRow(row, p, instance, spec)
			return
		}
		a.buildNoteRow(row, p, instance, spec)
	case buildRowDependency:
		a.buildDependencyRow(row, p, instance, spec)
	case buildRowTest:
		a.buildTestRow(row, p, instance, spec)
	case buildRowOptionChoice:
		a.buildOptionChoiceRow(row, p, instance, spec)
	default:
		a.buildItemRow(row, p, instance, spec)
	}
}

// buildTreeRowElement styles a row of the build tree as the other trees of the workbench are:
// its height, its indentation by level, and the selection or the hover behind it.
func (a *App) buildTreeRowElement(row ui.ListRow, spec buildRow) ui.Box {
	element := row.Element.Height(treelist.RowHeight).Items(ui.Center).Gap(treelist.Gap).
		PadSides(0, float32(treelist.Gutter+treelist.Trailing), 0, float32(treelist.Gutter+spec.level*treelist.Indent)).
		Radius(a.theme.Metrics.RadiusItem())
	if spec.selected {
		return element.Background(a.colors.Selection)
	}
	return element.Hover(ui.Look{}.Background(a.colors.Hover))
}

// buildArrow declares the arrow of a row that opens and closes, and reports a click on it; a
// row without children keeps the arrow's room empty, so its icon lines up with the icons of
// the rows beside it. title names the row for assistive technology.
func (a *App) buildArrow(c ui.C, title string, branch, open bool) bool {
	k := c.Part("arrow")
	if !branch {
		ui.Row(k).Size(treelist.Disclosure, treelist.Icon).Shrink(0)
		return false
	}
	name := i18n.Shared(a.language(), "native.collapseSection")
	if !open {
		name = i18n.Shared(a.language(), "native.expandSection")
	}
	slot := ui.Row(k).Size(treelist.Disclosure, treelist.Icon).Shrink(0).Center().
		HitWith(ui.ID(k), name+" "+title, gfx.HitOptions{Role: gfx.RoleButton, Cursor: gfx.PointerCursorHand, Expandable: true, Expanded: open, SkipFocus: true})
	slot.Children(func() {
		ui.Icon(c, fileicons.TreeChevron(open, a.colors.Dark)).Size(16, 16)
	})
	return slot.Clicked()
}

// buildSystemBadge declares the first letter of a build system's name on a tinted square of
// its color, as the Structure window marks a symbol's kind.
func (a *App) buildSystemBadge(c ui.C, instance *buildInstance) {
	hues := symbolFamilyColors[buildSystemFamily(instance.BuildSystemID)]
	color := gfx.RGB24(hues[0])
	tint := float32(0.14)
	if a.colors.Dark {
		color, tint = gfx.RGB24(hues[1]), 0.22
	}
	mark := ""
	if first, _ := utf8.DecodeRuneInString(buildSystemName(instance)); first != utf8.RuneError {
		mark = strings.ToUpper(string(first))
	}
	ui.Row(c).Size(treelist.Icon, treelist.Icon).Shrink(0).Center().Radius(4).Background(color.WithAlpha(tint)).Children(func() {
		ui.Text(c, mark).FontSize(10).Weight(gfx.WeightBold).Color(color)
	})
}

// buildGroupRow declares the row of one build system: its arrow, badge, name and root, and
// whether its model loads or failed. When the model has one root project the row stands for
// it, as IntelliJ's root node does: it shows the project's name, with the build system's
// name and root in its hover hint, and its menu has the project's items. A click selects the
// build system, the one the window's actions act on; the arrow or a double click opens or
// closes it. The selected build system's row has the buttons that load its model again and
// open its options.
func (a *App) buildGroupRow(row ui.ListRow, p *project, instance *buildInstance, spec buildRow) {
	c, b := row.C, &p.build
	index := spec.instance
	root := ""
	if spec.node != nil {
		root = spec.node.ProjectID
	}
	// The group row shows as chosen while its build system is selected and nothing in it is,
	// or only the project it stands for.
	look := spec
	look.selected = spec.selected && (b.projectID == "" || b.projectID == root) && b.targetID == "" && b.taskID == ""
	element := a.buildTreeRowElement(row, look)
	label := spec.label
	if spec.node != nil {
		label = spec.node.Label
		tip := spec.label
		if spec.detail != "" {
			tip += "\n" + spec.detail
		}
		element = element.Tooltip(tip)
	}
	toggled := a.buildArrow(c, label, !spec.fixed, spec.open)
	a.buildSystemBadge(c.Part("badge"), instance)
	ui.Text(c, label).FontSize(treeFontSize).Weight(gfx.WeightSemibold).Color(treelist.Text(a.colors.Dark)).Ellipsis().Shrink(0)
	if spec.detail != "" {
		ui.Text(c, spec.detail).FontSize(treeFontSize - 1).Color(a.colors.Subtle).Ellipsis().Shrink(1).MinWidth(0)
	}
	switch {
	case spec.loading:
		ui.Spinner(c).Size(12, 12)
	case spec.warning:
		ui.Icon(c, icons.CircleAlert).Size(14, 14).Shrink(0).Color(a.colors.Warning)
	}
	ui.Spacer(c)
	language := a.language()
	options := instance.hasDeclaredOptions()
	if spec.selected {
		if a.gitIconButton(c.Part("reload"), i18n.Shared(language, "native.reload"), icons.RefreshCw, false, instance.modelLoading || b.operation != nil) {
			c.After(func() {
				a.performed("build.model.reload", surfaceButton)
				a.reloadBuildModel(p, index)
			})
		}
		if options && a.gitIconButton(c.Part("options"), i18n.SharedFormat(language, "desktop.build.instanceOptions", map[string]string{"name": buildSystemName(instance)}), icons.Settings, false, false) {
			c.After(func() {
				a.performed("build.options.open", surfaceButton)
				a.openBuildOptions(p, p.selectedBuildInstance())
			})
		}
	}
	fixed, open := spec.fixed, spec.open
	switch {
	case !fixed && (toggled || element.DoubleClicked()):
		c.After(func() {
			a.performed("build.group.toggle", surfaceButton)
			p.setBuildGroupOpen(index, !open)
		})
	case element.Clicked():
		c.After(func() {
			a.performed("build.group.select", surfaceButton)
			if index == b.selected {
				b.projectID, b.targetID, b.taskID = "", "", ""
				return
			}
			// Selecting a group leaves it open or closed as it showed.
			shown := p.buildGroupOpen(index)
			a.chooseBuildInstance(p, index)
			p.setBuildGroupOpen(index, shown)
		})
	}
	ui.ContextMenu(c, element, func(menu *ui.MenuItems) {
		menu.WidthRange(180, 280)
		if menu.Item(i18n.Shared(language, "native.reload")).Disabled(instance.modelLoading || b.operation != nil).Clicked() {
			c.After(func() {
				a.performed("build.model.reload", surfaceContextMenu)
				a.reloadBuildModel(p, index)
			})
		}
		if options && menu.Item(i18n.SharedFormat(language, "desktop.build.instanceOptions", map[string]string{"name": buildSystemName(instance)})).Clicked() {
			c.After(func() {
				a.performed("build.options.open", surfaceContextMenu)
				a.chooseBuildInstance(p, index)
				a.openBuildOptions(p, p.selectedBuildInstance())
			})
		}
		if root != "" {
			a.buildProjectMenuItems(c, menu, p, instance, index, root)
		}
	})
}

// buildFolderIcons are the icons of the rows that head other nodes, by the kind of node: the
// IntelliJ New UI icons of the same folders in IntelliJ's Maven and Gradle tool windows.
var buildFolderIcons = map[string]fileicons.BuildNode{
	core.BuildTreeFolder:       fileicons.BuildTaskFolder,
	core.BuildTreeOption:       fileicons.BuildTaskFolder,
	core.BuildTreeTargets:      fileicons.BuildTargets,
	core.BuildTreeDependencies: fileicons.BuildDependencies,
	core.BuildTreeTests:        fileicons.BuildTests,
}

// buildFolderRow declares a row that heads other nodes: a task folder (a Maven project's
// Lifecycle or Plugins, a plugin's goals), a project's targets, its dependencies or the
// discovered tests. A click opens or closes it, unless a filter keeps it open. The
// Dependencies and Discovered Tests rows have the menu of their rows, and the Dependencies
// row the ⓘ that says when its tree is read.
func (a *App) buildFolderRow(row ui.ListRow, p *project, instance *buildInstance, spec buildRow) {
	c, node := row.C, spec.node
	element := a.buildTreeRowElement(row, spec)
	if spec.tooltip != "" {
		element = element.Tooltip(spec.tooltip)
	}
	toggled := a.buildArrow(c, spec.label, spec.branch && !spec.fixed, spec.open)
	if icon, ok := buildFolderIcons[node.Kind]; ok {
		ui.Icon(c, fileicons.ForBuildNode(icon, a.colors.Dark)).Size(treelist.Icon, treelist.Icon).Shrink(0)
	}
	ui.Text(c, spec.label).FontSize(treeFontSize).Color(treelist.Text(a.colors.Dark)).Ellipsis().Shrink(1).MinWidth(0)
	if spec.detail != "" {
		ui.Text(c, spec.detail).FontSize(treeFontSize - 1).Color(a.colors.Subtle).Ellipsis().Shrink(buildDetailShrink).MinWidth(0)
	}
	if node.Kind == core.BuildTreeDependencies {
		// Opening the node runs the build tool, so the ⓘ says when that happens and how to read
		// the tree again.
		language := a.language()
		ui.Button(c.Part("help"), i18n.Shared(language, "native.moreInformation")).Icon(icons.Info).IconOnly().Ghost().Size(18, 18).
			Tooltip(i18n.Shared(language, "desktop.build.dependenciesHelp")).TooltipOn(ui.TooltipRight)
	}
	ui.Spacer(c)
	if spec.branch && !spec.fixed && (toggled || element.Clicked()) {
		key := buildOpenKey(instance.ID, node.Key)
		state := buildOpenState{open: !spec.open, dependencies: node.Kind == core.BuildTreeDependencies}
		c.After(func() {
			a.performed("build.folder.toggle", surfaceButton)
			p.setBuildOpen(key, state)
		})
	}
	switch node.Kind {
	case core.BuildTreeDependencies:
		a.buildDependencyMenu(c, element, p, instance, node.ProjectID)
	case core.BuildTreeTests:
		a.buildTestsMenu(c, element, p, instance)
	}
}

// buildNoteRow declares a line that stands for rows not there: a model, its tree or a
// dependency tree that loads, failed or is empty, or a tree cut short. The dependency lines
// have the menu of the tree, and a model that failed has the item that loads it again. A line
// about a model load shows, while the load runs, the last line of the build tool's output, and
// a click on it shows the load's whole output in the Run window.
func (a *App) buildNoteRow(row ui.ListRow, p *project, instance *buildInstance, spec buildRow) {
	c := row.C
	element := a.buildTreeRowElement(row, spec)
	ui.Row(c.Part("arrow")).Size(treelist.Disclosure, treelist.Icon).Shrink(0)
	color := a.colors.Subtle
	switch {
	case spec.loading:
		ui.Spinner(c).Size(12, 12)
	case spec.warning:
		color = a.colors.Warning
		ui.Icon(c, icons.CircleAlert).Size(14, 14).Shrink(0).Color(color)
	}
	ui.Text(c, spec.label).FontSize(treeFontSize - 1).Color(color).Ellipsis().Shrink(1).MinWidth(0)
	if spec.detail != "" {
		ui.Text(c, spec.detail).FontSize(treeFontSize - 1).Color(a.colors.Subtle).Ellipsis().Shrink(buildDetailShrink).MinWidth(0)
	}
	if spec.tooltip != "" {
		element = element.Tooltip(spec.tooltip)
	}
	if spec.sync != "" && element.Clicked() {
		id := spec.sync
		c.After(func() {
			a.performed("build.sync.show", surfaceButton)
			a.showBuildSync(p, id)
		})
	}
	if spec.dependencies {
		a.buildDependencyMenu(c, element, p, instance, spec.project)
		return
	}
	if spec.model {
		index := spec.instance
		ui.ContextMenu(c, element, func(menu *ui.MenuItems) {
			menu.WidthRange(180, 280)
			if menu.Item(i18n.Shared(a.language(), "native.reload")).Disabled(instance.modelLoading || p.build.operation != nil).Clicked() {
				c.After(func() {
					a.performed("build.model.reload", surfaceContextMenu)
					a.reloadBuildModel(p, index)
				})
			}
		})
	}
}

// buildItemIcons are the icons of the rows a user chooses or runs that have nothing to run.
var buildItemIcons = map[buildRowKind]fileicons.BuildNode{
	buildRowProject: fileicons.BuildProject,
	buildRowTarget:  fileicons.BuildTarget,
	buildRowTask:    fileicons.BuildTask,
}

// buildDetailShrink is how much faster than its name a row's detail gives way when the row is
// too narrow for both: the path goes first, and the name gives way only once the path is gone.
const buildDetailShrink = 1000

// buildRunMark declares the green triangle that leads a row that runs, in the place of its
// kind's icon, as IntelliJ's Make window marks every target it runs, and reports a click on
// it. label names what the click starts, for its hover hint and for assistive technology.
// While a build operation runs or the model loads, the triangle is dimmed and takes no click,
// and a click there falls to the row.
func (a *App) buildRunMark(c ui.C, label string, disabled bool) bool {
	k := c.Part("run")
	// As wide as the icons of the rows beside it, so the names line up.
	slot := ui.Row(k).Size(treelist.Icon, treelist.Icon).Shrink(0).Center()
	if disabled {
		slot.Children(func() {
			ui.Icon(c, icons.Play).Size(14, 14).Color(a.colors.Subtle).Opacity(0.5)
		})
		return false
	}
	slot = slot.HitWith(ui.ID(k), label, gfx.HitOptions{Role: gfx.RoleButton, Cursor: gfx.PointerCursorHand, SkipFocus: true}).Tooltip(label)
	slot.Children(func() {
		ui.Icon(c, icons.Play).Size(14, 14).Color(a.colors.Success)
	})
	return slot.Clicked()
}

// buildItemTip is the hover hint of a project, target or task row: its whole name and, under
// it, its whole detail, which a narrow window cuts short; or the tooltip Core gave the node:
// a task's description, or the full name of a target that shows only its path.
func buildItemTip(spec buildRow) string {
	if spec.tooltip != "" {
		return spec.tooltip
	}
	if spec.detail == "" || spec.detail == spec.label {
		return spec.label
	}
	return spec.label + "\n" + spec.detail
}

// buildItemRow declares a project, target or task: its arrow when it holds other nodes, its
// icon, name and detail. A task, and a target that has a run, lead with the green triangle
// that runs it; the others lead with the icon of their kind. A click chooses the row, in its
// build system, which it selects first, and a click on the row already chosen lets it go; the
// arrow opens or closes it; a double click runs a task or a target's first run, and opens a
// project's build file. The chosen target whose first run debugs has the button that debugs
// it. When the row is too narrow, the detail gives way before the name, and the hover hint
// shows both whole.
func (a *App) buildItemRow(row ui.ListRow, p *project, instance *buildInstance, spec buildRow) {
	c, b, node := row.C, &p.build, spec.node
	element := a.buildTreeRowElement(row, spec)
	if tip := buildItemTip(spec); tip != "" {
		element = element.Tooltip(tip)
	}
	// A task waits for the Build window's operation; a target's run runs beside it and the
	// other runs.
	busy := instance.modelLoading || spec.kind == buildRowTask && b.operation != nil
	index := spec.instance
	// choose makes the row the window's choice, the node's project, target and task as Core
	// placed it; run, when set, then starts what it runs.
	choose := func() {
		a.chooseBuildInstance(p, index)
		b.projectID, b.targetID, b.taskID = node.ProjectID, node.TargetID, node.TaskID
	}
	var run func()
	var debug func()
	runLabel := ""
	switch spec.kind {
	case buildRowTask:
		// Every task row has its triangle, so each names its own task.
		runLabel = a.text.Build.RunTarget(spec.label)
		run = func() { a.runSelectedBuildTask(p) }
	case buildRowTarget:
		if action, ok := buildPrimaryAction(instance, spec.target); ok {
			targetID := node.TargetID
			runLabel = a.text.Build.RunTarget(action.name)
			run = func() { a.runBuildTargetAction(p, targetID, action) }
			if action.debug {
				debug = func() { a.debugBuildTarget(p, targetID, action.runID) }
			}
		}
	}
	if a.buildArrow(c, spec.label, spec.branch && !spec.fixed, spec.open) {
		key, state := buildOpenKey(instance.ID, node.Key), buildOpenState{open: !spec.open}
		c.After(func() {
			a.performed("build.node.toggle", surfaceButton)
			p.setBuildOpen(key, state)
		})
	}
	if run != nil {
		if a.buildRunMark(c, runLabel, busy) {
			c.After(func() {
				a.performed("build.item.run", surfaceButton)
				choose()
				run()
				a.showBuildConsole(p)
			})
		}
	} else if icon, ok := buildItemIcons[spec.kind]; ok {
		ui.Icon(c, fileicons.ForBuildNode(icon, a.colors.Dark)).Size(treelist.Icon, treelist.Icon).Shrink(0)
	}
	ui.Text(c, spec.label).FontSize(treeFontSize).Color(treelist.Text(a.colors.Dark)).Ellipsis().Shrink(1).MinWidth(0)
	if spec.detail != "" {
		ui.Text(c, spec.detail).FontSize(treeFontSize - 1).Color(a.colors.Subtle).Ellipsis().Shrink(buildDetailShrink).MinWidth(0)
	}
	ui.Spacer(c)
	if spec.selected && debug != nil && a.gitIconButton(c.Part("debug"), i18n.Shared(a.language(), "desktop.build.debugTarget"), icons.Bug, false, busy || p.debug.preparing) {
		c.After(func() {
			a.performed("build.target.debug", surfaceButton)
			choose()
			debug()
		})
	}
	switch {
	case element.DoubleClicked():
		switch {
		case spec.kind == buildRowProject:
			c.After(func() {
				a.performed("build.project.openBuildFile", surfaceButton)
				a.openBuildFile(p, instance, node.ProjectID)
			})
		case run != nil && !busy:
			c.After(func() {
				a.performed("build.item.run", surfaceButton)
				choose()
				run()
				a.showBuildConsole(p)
			})
		}
	case element.Clicked():
		selected := spec.selected
		c.After(func() {
			a.performed("build.item.choose", surfaceButton)
			if !selected {
				choose()
				return
			}
			b.projectID, b.targetID, b.taskID = "", "", ""
		})
	}
	a.buildRowMenu(c, element, p, instance, spec)
}

// buildOptionChoiceRow declares one choice of a tree-presented multi-select option: its empty
// arrow slot, its checkbox, its choice label and its default-active badge when the model marks
// it active by default. Clicking the checkbox or the row toggles the choice in the project's
// local Build options and reloads the build systems.
func (a *App) buildOptionChoiceRow(row ui.ListRow, p *project, instance *buildInstance, spec buildRow) {
	c, b, node := row.C, &p.build, spec.node
	element := a.buildTreeRowElement(row, spec)
	if tip := buildItemTip(spec); tip != "" {
		element = element.Tooltip(tip)
	}
	busy := b.operation != nil || b.loading || b.optionSaving || instance.modelLoading
	checked := node.Checked
	toggleLabel := i18n.SharedFormat(a.language(), "desktop.build.toggleOptionChoice", map[string]string{
		"option": spec.optionTitle,
		"choice": spec.label,
	})
	ui.Row(c.Part("arrow")).Size(treelist.Disclosure, treelist.Icon).Shrink(0)
	var boxClicked bool
	ui.Row(c.Part("content")).Grow(1).Shrink(1).MinWidth(0).Items(ui.Center).Gap(changeTreeGap).Children(func() {
		boxClicked = a.treeCheckbox(c.Part("check"), &checked, toggleLabel).Disabled(busy).Clicked()
		ui.Text(c, spec.label).FontSize(treeFontSize).Color(treelist.Text(a.colors.Dark)).Ellipsis().Shrink(1).MinWidth(0)
		if spec.detail != "" {
			ui.Text(c, spec.detail).FontSize(treeFontSize - 1).Color(a.colors.Subtle).Ellipsis().Shrink(buildDetailShrink).MinWidth(0)
		}
	})
	if !busy && (boxClicked || element.Clicked()) {
		index, optionID, choiceValue := spec.instance, node.OptionID, node.OptionValue
		c.After(func() {
			a.performed("build.optionChoice.toggle", surfaceButton)
			a.chooseBuildInstance(p, index)
			a.toggleBuildTreeOptionChoice(p, index, optionID, choiceValue)
		})
	}
}
