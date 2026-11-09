package workbench

import (
	"math"
	"path"
	"slices"
	"strconv"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/fileicons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/hscroll"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/monogrid"
	"github.com/1lck/Lithe-IDEA/desktop/internal/treelist"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// This file declares the log tab of the Git tool window, laid out as the macOS log is:
// the action stripe of the reference pane, the reference pane, the commit list with its
// filter bar, and the details pane with the changed files over the commit details. What
// the list rows show is painted by gitgraph.go into the rows declared here.

const (
	logToolbarHeight = 38
	logStripeWidth   = 36
	logButtonSize    = 24
	logRefsWidth     = 220
	logRefsMin       = 160
	logCommitsMin    = 340
	logDetailsWidth  = 350
	logDetailsMin    = 250
	logFilesHeight   = 180
	logFilesMin      = 90
	logCommitMin     = 110
	// logDetailPad is the padding around the commit details.
	logDetailPad     = 12
	logIndent        = 14
	logItemHeight    = 24
	logPopoverWidth  = 240
	logPathWidth     = 320
	logListMaxHeight = 320
)

// The reference chips under the author line of the commit details. drawLogRefChip lays a
// chip out and refRows measures it with the same numbers, so they must change together: a
// chip is logRefChipPad on either side of a logRefIconSize tag icon, logRefChipGap and the
// name, and chips stand logRefChipGap apart along a line and between the lines they wrap
// onto.
const (
	logRefChipHeight = 20
	logRefChipPad    = 6
	logRefIconSize   = 12
	logRefChipGap    = 4
)

// The author line of the commit details: the short hash, the author, the email and the
// date. drawLogMeta lays the parts out and metaRows measures them with the same numbers:
// parts stand logAuthorGap apart along a line, and the lines they wrap onto logAuthorLineGap.
const (
	logAuthorGap     = 6
	logAuthorLineGap = 2
)

// logMetaPart is one part of the author line of the commit details, drawn whole in color,
// in the fixed-pitch font when mono is set.
type logMetaPart struct {
	text  string
	mono  bool
	color gfx.Color
}

var (
	logSearchID     = tree.ID(shellPage, "log-search")
	logRefSearchID  = tree.ID(shellPage, "log-ref-search")
	logUserSearchID = tree.ID(shellPage, "log-user-search")
	logPathID       = tree.ID(shellPage, "log-path")
	logListID       = tree.ID(shellPage, "log-list")
	logRefListID    = tree.ID(shellPage, "log-refs")
	logFilesID      = tree.ID(shellPage, "log-files")
	logDetailID     = tree.ID(shellPage, "log-detail")
	logUserListID   = tree.ID(shellPage, "log-user-list")
	logBranchListID = tree.ID(shellPage, "log-branch-list")
	logSplitRefs    = tree.ID(shellPage, "log-split-refs")
	logSplitDetails = tree.ID(shellPage, "log-split-details")
	logSplitFiles   = tree.ID(shellPage, "log-split-files")
	logDismiss      = tree.ID(shellPage, "log-popover-dismiss")
	logRetryMore    = tree.ID(shellPage, "log-retry-more")
	logLoadMoreID   = tree.ID(shellPage, "log-load-more")
	logRetryFiles   = tree.ID(shellPage, "log-retry-files")
	logPathClear    = tree.ID(shellPage, "log-path-clear")
	logPathCancel   = tree.ID(shellPage, "log-path-cancel")
	logPathApply    = tree.ID(shellPage, "log-path-apply")

	logRows       = tree.Sub(shellPage, tree.Name("log-rows"))
	logRefRows    = tree.Sub(shellPage, tree.Name("log-ref-rows"))
	logFileRows   = tree.Sub(shellPage, tree.Name("log-file-rows"))
	logFileArrows = tree.Sub(shellPage, tree.Name("log-file-arrows"))
	logButtons    = tree.Sub(shellPage, tree.Name("log-buttons"))
	logChips      = tree.Sub(shellPage, tree.Name("log-chips"))
	logItems      = tree.Sub(shellPage, tree.Name("log-popover-items"))

	// logFileList is the tree of the selected commit's changed files. A folder's row has the
	// key of its index in the commit's folders, and a file's row the number of folders plus
	// its index in the commit's files.
	logFileList = treelist.List{Scroll: logFilesID, Rows: logFileRows, Arrows: logFileArrows}
)

// The icon buttons of the log tab, for logButtons.At.
const (
	logButtonHide = iota
	logButtonShow
	logButtonNew
	logButtonUpdate
	logButtonDelete
	logButtonCompareRef
	logButtonFind
	logButtonFetch
	logButtonLocate
	logButtonSettings
	logButtonExpand
	logButtonCollapse
	logButtonCompare
	logButtonDetails
	logButtonRefresh
	logButtonDecorations
	logButtonFindLog
	logButtonLongEdges
	logButtonShowAll
	logButtonMenu
	logButtonCompareFile
	logButtonFileHistory
)

// The filter chips of the commit list, for logChips.At and logView.chips.
const (
	logChipBranch = iota
	logChipUser
	logChipDate
	logChipPath
	logChipCount
)

// logView is the window's state of the log tab that is not the project's: the fields,
// the splitters, and what the frame declared for the paint after it.
type logView struct {
	search, refSearch, userSearch, pathField ui.Field

	refSplit, detailSplit, filesSplit ui.SplitterState
	// detailWidth is the chosen width of the details pane; the commit list takes what
	// is left, so the details keep their width when the tool window is resized.
	detailWidth float32
	// bodyWidth is the width the commit list and the details shared in the last frame,
	// and derived the detail splitter's position that frame was declared with.
	bodyWidth, derived float32

	// body, list, rows, chips and menu are boxes of the frame being drawn; they are
	// valid until the next frame starts. hasBody says body was declared.
	body    ui.Box
	hasBody bool
	details bool
	list    ui.Box
	rows    []logPaintRow
	chips   [logChipCount]ui.Box
	menu    ui.Box
	hasMenu bool

	// subject is the selected commit's subject broken into the lines the commit details draw
	// it in: subjectOf, in the details subjectWidth wide, with the fonts of subjectFonts.
	subject      []string
	subjectOf    string
	subjectWidth float32
	subjectFonts uint32
	// refWidths are the widths refRows measured the selected commit's reference chips at, and
	// refStarts the index of the first chip of each line they wrap onto; both are kept so the
	// next frame reuses their arrays.
	refWidths []float32
	refStarts []int
	// metaParts are the parts of the selected commit's author line, metaWidths the widths
	// metaRows measured them at, and metaStarts the index of the first part of each line
	// they wrap onto; all are kept so the next frame reuses their arrays.
	metaParts  []logMetaPart
	metaWidths []float32
	metaStarts []int

	// file is the path of the selected changed file, and folder the path of the selected
	// folder of the changed files; at most one of them is set.
	file, folder string
	// fileRows are the rows of the changed files as the tree list draws them, and fileItems
	// what each row is; fileSelected is the index of the selected row, -1 for none.
	fileRows     []treelist.Row
	fileItems    []logFileItem
	fileSelected int
	// fileScroll scrolls the changed files sideways, so a long name is never cut short.
	// fileArea is their list in the frame being drawn, and filesDrawn says the frame
	// declared it. fileWidthKeys, fileWidthOf and fileWidthFont are the rows, the commit
	// and the font size fileScroll.Content was measured for.
	fileScroll    hscroll.State
	fileArea      ui.Box
	filesDrawn    bool
	fileWidthKeys []int
	fileWidthOf   string
	fileWidthFont float32
	// focus is the field to give the keyboard to in the next frame.
	focus gfx.ID

	colors       map[int32]gfx.Color
	colorsDark   bool
	dates        map[string]string
	upstream     map[string]string
	upstreamFor  *logSection
	upstreamRefs int
}

// logPaintRow is one commit row the frame declared: its box and its row of the graph.
type logPaintRow struct {
	box   ui.Box
	index int
}

func newLogView() logView {
	v := logView{detailWidth: logDetailsWidth}
	v.refSplit.Pos = logRefsWidth
	v.filesSplit.Pos = logFilesHeight
	return v
}

// reset empties the fields for a project that was just opened.
func (v *logView) reset() {
	for _, field := range []*ui.Field{&v.search, &v.refSearch, &v.userSearch, &v.pathField} {
		field.SetText("")
	}
	v.file, v.folder = "", ""
	v.dates = nil
	v.upstream = nil
}

// beginFrame forgets the boxes of the last frame.
func (v *logView) beginFrame() {
	v.rows = v.rows[:0]
	v.hasBody, v.hasMenu, v.details = false, false, false
}

// capture keeps the width the commit list and the details shared, and takes a drag of
// the detail splitter as a new width of the details.
func (v *logView) capture() {
	if !v.hasBody {
		return
	}
	width := v.body.Rect().Width
	if v.details && v.detailSplit.Dragging() && v.detailSplit.Pos != v.derived && v.bodyWidth > 0 {
		v.adoptDetails()
	}
	v.bodyWidth = width
}

// adoptDetails takes the detail splitter's position as the width of the details.
func (v *logView) adoptDetails() {
	room := v.bodyWidth - shellSplitter
	v.detailWidth = min(max(room-v.detailSplit.Pos, logDetailsMin), max(room-logCommitsMin, logDetailsMin))
}

// key gives a key press to the log tab: Escape closes a popover, a focused splitter
// takes the arrows, and the commit list takes Up and Down while it has the keyboard.
func (a *App) logKey(event gfx.KeyEvent) gfx.EventResult {
	p := a.project
	if p == nil || a.layout.gitTab != 0 || !p.log.started {
		return gfx.EventResult{}
	}
	v, l := &a.logView, &p.log
	if event.Key == gfx.KeyEscape && l.popover != logPopoverNone {
		l.popover = logPopoverNone
		return gfx.EventResult{Handled: true, Repaint: true}
	}
	if r := v.refSplit.Key(event); r.Handled {
		return r
	}
	if r := v.filesSplit.Key(event); r.Handled {
		return r
	}
	if r := v.detailSplit.Key(event); r.Handled {
		v.adoptDetails()
		return r
	}
	switch event.Target {
	case logSearchID, logRefSearchID, logUserSearchID, logPathID:
		return gfx.EventResult{}
	}
	if l.popover == logPopoverNone {
		if r, ok := a.logFilesKey(p, event); ok {
			return r
		}
	}
	if !l.listFocus || l.popover != logPopoverNone {
		return gfx.EventResult{}
	}
	delta := 0
	switch event.Key {
	case gfx.KeyUp:
		delta = -1
	case gfx.KeyDown:
		delta = 1
	default:
		return gfx.EventResult{}
	}
	if a.moveLogSelection(p, delta) {
		return gfx.EventResult{Handled: true, Repaint: true}
	}
	return gfx.EventResult{}
}

// drawLogHeaderLeading declares what the log tab adds after the tabs of the header:
// the button that shows every reference again once the log walks one.
func (a *App) drawLogHeaderLeading(f *ui.Frame, p *project) {
	if p.log.reference == "" {
		return
	}
	if a.logIconButton(f, logButtons.At(logButtonShowAll), a.text.Git.ShowAll, icons.Plus, false, false) {
		p.log.refSelected = ""
		a.setLogReference(p, "", "")
	}
}

// drawLogHeaderTrailing declares the log tab's menu button before the hide button.
func (a *App) drawLogHeaderTrailing(f *ui.Frame, p *project) {
	var button ui.Box
	if a.toolIconButton(f, logButtons.At(logButtonMenu), a.text.Git.Actions, icons.EllipsisVertical, p.log.popover == logPopoverMenu, false, &button) {
		a.toggleLogPopover(p, logPopoverMenu)
	}
	a.logView.menu, a.logView.hasMenu = button, true
}

// drawGitLog declares the body of the log tab.
func (a *App) drawGitLog(f *ui.Frame, p *project) {
	l, v := &p.log, &a.logView
	if !l.started {
		a.loadLog(p)
	}
	a.syncLogFilters(p)
	if focused := f.Canvas().Focused(); focused == logSearchID || focused == logRefSearchID || focused == logUserSearchID || focused == logPathID {
		l.listFocus = false
	}
	f.Row().Fill().Background(a.colors.Editor).Children(func() {
		if l.branchesHidden {
			a.drawLogHiddenStripe(f, p)
		} else {
			a.drawLogStripe(f, p)
			f.Divider()
			a.drawLogReferences(f, p).Width(v.refSplit.Pos).Shrink(0)
			f.Splitter(logSplitRefs, &v.refSplit).Mins(logRefsMin, logCommitsMin).Label(a.text.Panel.Resize)
		}
		v.body = f.Row().Grow(1).Children(func() {
			v.details = l.showDetails
			if !l.showDetails {
				a.drawLogCommits(f, p).Grow(1)
				return
			}
			if v.bodyWidth > 0 && !v.detailSplit.Dragging() {
				v.derived = max(v.bodyWidth-shellSplitter-v.detailWidth, logCommitsMin)
				v.detailSplit.Pos = v.derived
			}
			a.drawLogCommits(f, p).Grow(1)
			f.Splitter(logSplitDetails, &v.detailSplit).Mins(logCommitsMin, logDetailsMin).Label(a.text.Panel.Resize)
			a.drawLogDetails(f, p).Width(v.detailWidth).Shrink(0)
		})
		v.hasBody = true
	})
	a.drawLogPopover(f, p)
	if !v.focus.IsZero() {
		f.Canvas().RequestFocus(v.focus)
		v.focus = gfx.ID{}
	}
}

// syncLogFilters applies the text typed into the filter field once the typing stops.
func (a *App) syncLogFilters(p *project) {
	l := &p.log
	if text := strings.TrimSpace(a.logView.search.Text()); text != l.text {
		l.text = text
		if !l.loading {
			a.reproject(p, a.delays.filter)
		}
	}
}

// drawLogStripe declares the action stripe of the reference pane.
func (a *App) drawLogStripe(f *ui.Frame, p *project) {
	l := &p.log
	g := a.text.Git
	selected, hasSelected := l.findReference(l.refSelected)
	deletable := hasSelected && selected.Kind == "local" && !selected.IsCurrent
	compare := g.CompareWorkingTree
	if hasSelected && !selected.IsCurrent {
		compare = g.CompareWithCurrent
	}
	f.Column().Width(logStripeWidth).Shrink(0).FillHeight().Items(ui.Center).PadY(6).Gap(4).Background(a.colors.Panel).Children(func() {
		if a.logIconButton(f, logButtons.At(logButtonHide), g.HideBranches, icons.ChevronLeft, false, false) {
			l.branchesHidden = true
		}
		f.Divider().Width(20)
		if a.logIconButton(f, logButtons.At(logButtonNew), g.NewBranch, icons.Plus, false, false) {
			a.notify(a.text.Welcome.Unavailable)
		}
		if a.logIconButton(f, logButtons.At(logButtonUpdate), g.UpdateBranch, icons.ArrowDownLeft, false, l.current == "") {
			a.notify(a.text.Welcome.Unavailable)
		}
		if a.logIconButton(f, logButtons.At(logButtonDelete), g.DeleteBranch, icons.Trash2, false, !deletable) {
			a.notify(a.text.Welcome.Unavailable)
		}
		if a.logIconButton(f, logButtons.At(logButtonCompareRef), compare, icons.ArrowLeftRight, false, !hasSelected) {
			a.notify(a.text.Welcome.Unavailable)
		}
		if a.logIconButton(f, logButtons.At(logButtonFind), g.FindBranch, icons.Search, false, false) {
			a.logView.focus = logRefSearchID
		}
		if a.logIconButton(f, logButtons.At(logButtonFetch), g.Fetch, icons.CloudDownload, false, false) {
			a.notify(a.text.Welcome.Unavailable)
		}
		if a.logIconButton(f, logButtons.At(logButtonLocate), g.LocateBranch, icons.Locate, false, !hasSelected && l.current == "") {
			short := l.current
			if hasSelected {
				short = selected.ShortName
			}
			a.locateReference(p, short)
		}
		f.Divider().Width(20)
		if a.logIconButton(f, logButtons.At(logButtonSettings), g.BranchSettings, icons.Settings, false, false) {
			a.notify(a.text.Welcome.Unavailable)
		}
		if a.logIconButton(f, logButtons.At(logButtonExpand), g.ExpandAll, icons.ChevronsUpDown, false, false) {
			clear(l.collapsed)
		}
		if a.logIconButton(f, logButtons.At(logButtonCollapse), g.CollapseAll, icons.ChevronsDownUp, false, false) {
			for _, s := range l.sections {
				l.collapsed["s"+s.kind] = true
			}
		}
	})
}

// drawLogHiddenStripe is the stripe that stands for the reference pane while it is hidden.
func (a *App) drawLogHiddenStripe(f *ui.Frame, p *project) {
	f.Column().Width(logStripeWidth).Shrink(0).FillHeight().Items(ui.Center).PadY(6).Gap(4).Background(a.colors.Panel).Children(func() {
		if a.logIconButton(f, logButtons.At(logButtonShow), a.text.Git.ShowBranches, icons.GitBranch, false, false) {
			p.log.branchesHidden = false
		}
	})
	f.Divider()
}

// drawLogReferences declares the reference pane: its search field over HEAD and the
// sections of local branches, remote branches and tags.
func (a *App) drawLogReferences(f *ui.Frame, p *project) ui.Box {
	l, v := &p.log, &a.logView
	query := strings.ToLower(strings.TrimSpace(v.refSearch.Text()))
	return f.Column().FillHeight().Background(a.colors.Panel).Clip().Children(func() {
		f.Row().Height(logToolbarHeight).Shrink(0).Items(ui.Center).PadX(6).Children(func() {
			f.Field(&v.refSearch, logRefSearchID, a.text.Git.BranchSearch, a.text.Git.BranchSearch).Grow(1)
		})
		f.Divider()
		n := 0
		f.ScrollArea(logRefListID).Grow(1).PadY(4).Children(func() {
			if query == "" {
				a.drawLogRefRow(f, p, &n, 0, icons.Tag, referenceColor("head", a.colors.Dark), a.text.Git.HeadRow, "", "HEAD", "HEAD")
			}
			shown := 0
			labels := [3]string{a.text.Git.LocalGroup, a.text.Git.RemoteGroup, a.text.Git.TagGroup}
			for i := range l.sections {
				s := &l.sections[i]
				if len(s.refs) == 0 {
					continue
				}
				if query != "" {
					matches := slices.DeleteFunc(slices.Clone(s.refs), func(r core.GitReference) bool {
						return !strings.Contains(strings.ToLower(r.ShortName), query)
					})
					if len(matches) == 0 {
						continue
					}
					shown += len(matches)
					a.drawLogSection(f, p, &n, labels[i], s.kind, true)
					for _, r := range matches {
						a.drawLogReference(f, p, &n, 1, r, r.ShortName)
					}
					continue
				}
				shown += len(s.refs)
				if a.drawLogSection(f, p, &n, labels[i], s.kind, !l.collapsed["s"+s.kind]) {
					a.drawLogNodes(f, p, &n, s, s.nodes, 1)
				}
			}
			if query != "" && shown == 0 {
				f.Text(a.text.Git.NoMatchingReferences).Muted().TextCenter().FillWidth().PadY(16)
			}
		})
	})
}

// drawLogSection declares the header row of a section and reports whether it is open.
func (a *App) drawLogSection(f *ui.Frame, p *project, n *int, label, kind string, open bool) bool {
	key := "s" + kind
	chevron := icons.ChevronRight
	if open {
		chevron = icons.ChevronDown
	}
	row := a.logTreeRow(f, logRefRows.At(*n), label, 0, false)
	*n++
	row.Children(func() {
		f.Icon(chevron).Size(12, 12).Color(a.colors.Subtle)
		f.Text(label).Weight(gfx.WeightMedium).Ellipsis().Grow(1)
	})
	if row.Clicked() {
		p.log.collapsed[key] = open
	}
	return open
}

// drawLogNodes declares the folders and references of a section's tree.
func (a *App) drawLogNodes(f *ui.Frame, p *project, n *int, s *logSection, nodes []core.ReferenceTreeNode, depth int) {
	for i := range nodes {
		node := &nodes[i]
		if node.Reference != nil {
			if r := *node.Reference; r >= 0 && r < len(s.refs) {
				a.drawLogReference(f, p, n, depth, s.refs[r], node.Name)
			}
			continue
		}
		key := "f" + s.kind + "/" + node.Path
		open := !p.log.collapsed[key]
		chevron := icons.ChevronRight
		if open {
			chevron = icons.ChevronDown
		}
		row := a.logTreeRow(f, logRefRows.At(*n), node.Name, depth, false)
		*n++
		row.Children(func() {
			f.Icon(chevron).Size(12, 12).Color(a.colors.Subtle)
			f.Icon(icons.Folder).Size(14, 14).Color(a.colors.Subtle)
			f.Text(node.Name).Ellipsis().Grow(1)
		})
		if row.Clicked() {
			p.log.collapsed[key] = open
		}
		if open {
			a.drawLogNodes(f, p, n, s, node.Children, depth+1)
		}
	}
}

// drawLogReference declares the row of one reference.
func (a *App) drawLogReference(f *ui.Frame, p *project, n *int, depth int, r core.GitReference, name string) {
	kind := map[string]string{"local": "branch", "remote": "remote", "tag": "tag"}[r.Kind]
	icon := icons.GitBranch
	switch {
	case r.Kind == "tag":
		icon = icons.Tag
	case r.IsCurrent:
		kind, icon = "head", icons.Tag
	}
	trailing := ""
	if r.Ahead > 0 {
		trailing = "↑" + strconv.Itoa(r.Ahead)
	}
	if r.Behind > 0 {
		trailing = strings.TrimSpace(trailing + " ↓" + strconv.Itoa(r.Behind))
	}
	a.drawLogRefRow(f, p, n, depth, icon, referenceColor(kind, a.colors.Dark), name, trailing, r.FullName, r.ShortName)
}

// drawLogRefRow declares a selectable reference row; selecting it makes the log walk it.
func (a *App) drawLogRefRow(f *ui.Frame, p *project, n *int, depth int, icon gfx.Icon, tint gfx.Color, label, trailing, full, short string) {
	l := &p.log
	row := a.logTreeRow(f, logRefRows.At(*n), label, depth, l.refSelected == full)
	*n++
	row.Children(func() {
		f.Row().Size(12, 12).Shrink(0)
		f.Icon(icon).Size(14, 14).Color(tint)
		f.Text(label).Ellipsis().Grow(1)
		if trailing != "" {
			f.Text(trailing).Muted().FontSize(a.theme.Metrics.FontSizeS).Shrink(0)
		}
	})
	if row.Clicked() {
		l.refSelected = full
		l.listFocus = false
		a.setLogReference(p, full, short)
	}
}

// logTreeRow is a row of the reference pane, indented by depth.
func (a *App) logTreeRow(f *ui.Frame, id gfx.ID, label string, depth int, selected bool) ui.Box {
	row := f.Row().Height(logItemHeight).FillWidth().Shrink(0).Items(ui.Center).Gap(4).
		PadSides(0, 8, 0, float32(6+depth*logIndent)).
		HitWith(id, label, gfx.HitOptions{Role: gfx.RoleButton})
	if selected {
		return row.Background(a.colors.Selection)
	}
	return row.Hover(ui.Look{}.Background(a.colors.Hover))
}

// drawLogCommits declares the commit pane: the filter bar over the list.
func (a *App) drawLogCommits(f *ui.Frame, p *project) ui.Box {
	return f.Column().FillHeight().MinWidth(logCommitsMin).Clip().Children(func() {
		a.drawLogToolbar(f, p)
		f.Divider()
		a.drawLogList(f, p)
	})
}

// drawLogToolbar declares the filter bar: the text filter, the filter chips and the
// view buttons.
func (a *App) drawLogToolbar(f *ui.Frame, p *project) {
	l, v, g := &p.log, &a.logView, a.text.Git
	f.Row().Height(logToolbarHeight).Shrink(0).Items(ui.Center).Gap(4).PadX(6).Children(func() {
		f.Field(&v.search, logSearchID, g.TextOrHash, g.TextOrHash).MinWidth(150).Grow(1).MaxWidth(320)
		dates := [logDateCount]string{g.AnyTime, g.Today, g.Yesterday, g.Last7Days, g.Last30Days}
		chips := [logChipCount]struct {
			label, value string
			popover      logPopover
		}{
			{g.FilterBranch, l.referenceLabel, logPopoverBranch},
			{g.FilterUser, l.user, logPopoverUser},
			{g.FilterDate, "", logPopoverDate},
			{g.FilterPaths, l.path, logPopoverPath},
		}
		if l.date != logAnyTime {
			chips[logChipDate].value = dates[l.date]
		}
		for i, chip := range chips {
			v.chips[i] = a.logChip(f, logChips.At(i), chip.label, chip.value, l.popover == chip.popover)
			if v.chips[i].Clicked() {
				a.toggleLogPopover(p, chip.popover)
			}
		}
		f.Spacer()
		if a.logIconButton(f, logButtons.At(logButtonCompare), g.CompareBranch, icons.ArrowLeftRight, false, false) {
			a.notify(a.text.Welcome.Unavailable)
		}
		if a.logIconButton(f, logButtons.At(logButtonDetails), g.ShowDetails, icons.PanelRight, l.showDetails, false) {
			l.showDetails = !l.showDetails
		}
		if a.logIconButton(f, logButtons.At(logButtonRefresh), g.RefreshLog, icons.RefreshCw, false, false) {
			a.loadLog(p)
		}
		decorations := icons.EyeOff
		if l.decorations {
			decorations = icons.Eye
		}
		if a.logIconButton(f, logButtons.At(logButtonDecorations), g.Decorations, decorations, false, false) {
			l.decorations = !l.decorations
		}
		if a.logIconButton(f, logButtons.At(logButtonFindLog), g.FindInLog, icons.Search, false, false) {
			v.focus = logSearchID
		}
		edges := icons.ArrowDownToLine
		if l.expanded {
			edges = icons.ArrowUpDown
		}
		if a.logIconButton(f, logButtons.At(logButtonLongEdges), g.LongEdges, edges, l.expanded, false) {
			l.expanded = !l.expanded
			if !l.loading {
				a.reproject(p, 0)
			}
		}
	})
}

// logChip declares a filter chip: its name, or the filter it applies, and a chevron.
func (a *App) logChip(f *ui.Frame, id gfx.ID, label, value string, open bool) ui.Box {
	text := label
	if value != "" {
		text = a.text.Git.FilterValue(label, value)
	}
	chip := f.Row().Height(logButtonSize).Shrink(0).Items(ui.Center).Gap(4).PadX(8).
		Radius(a.theme.Metrics.RadiusItem()).
		HitWith(id, text, gfx.HitOptions{Role: gfx.RoleButton, Cursor: gfx.PointerCursorHand})
	switch {
	case open:
		chip = chip.Background(a.colors.Active)
	case value != "":
		chip = chip.Background(a.colors.Hover)
	default:
		chip = chip.Hover(ui.Look{}.Background(a.colors.Hover))
	}
	chip.Children(func() {
		color := a.colors.Subtle
		if value != "" {
			color = a.colors.Text
		}
		f.Text(text).Color(color).MaxWidth(180).Ellipsis()
		f.Icon(icons.ChevronDown).Size(12, 12).Color(a.colors.Subtle)
	})
	return chip
}

// drawLogList declares the commit list, or what stands in for it. Only the rows in
// view are declared; spacers stand for the rest, so a long history costs what fits.
func (a *App) drawLogList(f *ui.Frame, p *project) {
	l, v, g := &p.log, &a.logView, a.text.Git
	switch {
	case !p.git.loaded || l.loading && len(l.commits) == 0:
		a.logEmpty(f, g.Loading)
		return
	case !p.git.isRepository():
		a.logEmpty(f, g.NotRepository)
		return
	case l.err != nil:
		a.logEmpty(f, g.Failed(l.err.Error()))
		return
	case len(l.commits) == 0:
		a.logEmpty(f, g.NoCommits)
		return
	case len(l.graph.Rows) == 0 && l.filtered():
		a.logEmpty(f, g.NoMatches)
		return
	}
	rows := l.graph.Rows
	s := a.view.ScrollState(logListID)
	if l.reveal {
		l.reveal = false
		if at := slices.IndexFunc(rows, func(r core.GraphRow) bool { return r.CommitHash == l.selected }); at >= 0 {
			top := float32(at) * logRowHeight
			switch {
			case top < s.Offset:
				s.ScrollTo(top)
			case top+logRowHeight > s.Offset+s.Viewport && s.Viewport > 0:
				s.ScrollTo(top + logRowHeight - s.Viewport)
			}
		}
	}
	viewport := s.Viewport
	if viewport <= 0 {
		viewport = 800
	}
	first := max(0, int(s.Offset/logRowHeight)-2)
	last := min(len(rows), int((s.Offset+viewport)/logRowHeight)+3)
	first = min(first, last)
	if l.hasMore && s.Content > 0 && s.Offset+s.Viewport >= s.Content-logLoadMoreMargin {
		a.loadMoreLog(p)
	}
	v.list = f.ScrollArea(logListID).Grow(1).FillWidth().Children(func() {
		if first > 0 {
			f.Row().Height(float32(first) * logRowHeight).Shrink(0)
		}
		for i := first; i < last; i++ {
			row := rows[i]
			commit, _ := l.commit(row.CommitHash)
			box := f.Row().Height(logRowHeight).FillWidth().Shrink(0).
				HitWith(logRows.At(i), commit.Subject, gfx.HitOptions{Role: gfx.RoleOption})
			switch {
			case row.CommitHash == l.selected:
				box = box.Background(a.colors.Selection)
			case l.currentRows[row.CommitHash]:
				box = box.Background(currentBranchBackground(a.colors.Dark)).Hover(ui.Look{}.Background(a.colors.Hover))
			default:
				box = box.Hover(ui.Look{}.Background(a.colors.Hover))
			}
			if box.Clicked() {
				l.listFocus = true
				a.selectCommit(p, row.CommitHash)
			}
			v.rows = append(v.rows, logPaintRow{box: box, index: i})
		}
		if rest := len(rows) - last; rest > 0 {
			f.Row().Height(float32(rest) * logRowHeight).Shrink(0)
		}
		a.drawLogFooter(f, p)
	})
}

// drawLogFooter declares the row under the list that loads the next page.
func (a *App) drawLogFooter(f *ui.Frame, p *project) {
	l, g := &p.log, a.text.Git
	if !l.hasMore && !l.loadingMore {
		return
	}
	f.Row().Height(logRowHeight * 1.5).FillWidth().Shrink(0).Items(ui.Center).Gap(8).PadX(12).Children(func() {
		f.Spacer()
		switch {
		case l.loadingMore:
			f.Text(g.LoadingCommits).Muted()
		case l.moreFailed:
			f.Text(g.LoadMoreFailed).Color(a.colors.Warning)
			if f.Button(logRetryMore, g.Retry).Ghost().Clicked() {
				l.moreFailed = false
				a.loadMoreLog(p)
			}
		default:
			if f.Button(logLoadMoreID, g.LoadMore).Ghost().Clicked() {
				a.loadMoreLog(p)
			}
		}
		f.Spacer()
	})
}

// logEmpty declares the message that stands for an empty pane.
func (a *App) logEmpty(f *ui.Frame, message string) {
	f.Column().Fill().Center().PadX(shellContentPad).Children(func() {
		f.Paragraph(message, 3).TextCenter().Color(a.colors.Subtle)
	})
}

// drawLogDetails declares the details pane: the changed files over the commit details.
func (a *App) drawLogDetails(f *ui.Frame, p *project) ui.Box {
	v := &a.logView
	return f.Column().FillHeight().Clip().Background(a.colors.Editor).Children(func() {
		a.drawLogFiles(f, p).Height(v.filesSplit.Pos).Shrink(0)
		f.Splitter(logSplitFiles, &v.filesSplit).Mins(logFilesMin, logCommitMin).Label(a.text.Panel.Resize)
		a.drawLogCommitDetail(f, p).Grow(1)
	})
}

// drawLogFiles declares the files the selected commit changed, grouped by folder.
func (a *App) drawLogFiles(f *ui.Frame, p *project) ui.Box {
	l, v, g := &p.log, &a.logView, a.text.Git
	if !slices.ContainsFunc(l.files, func(file core.GitCommitFile) bool { return file.Path == v.file }) {
		v.file = ""
	}
	if !slices.ContainsFunc(l.folders, func(folder logFolder) bool { return folder.dir == v.folder }) {
		v.folder = ""
	}
	return f.Column().FillWidth().Clip().Children(func() {
		f.Row().Height(logToolbarHeight).Shrink(0).Items(ui.Center).Gap(4).PadX(6).Children(func() {
			if a.logIconButton(f, logButtons.At(logButtonCompareFile), g.CompareChanges, icons.ArrowLeftRight, false, v.file == "") {
				a.notify(a.text.Welcome.Unavailable)
			}
			if a.logIconButton(f, logButtons.At(logButtonFileHistory), g.FileHistory, icons.Clock, false, v.file == "") {
				l.path = v.file
				v.pathField.SetText(v.file)
				if !l.loading {
					a.reproject(p, 0)
				}
			}
		})
		f.Divider()
		switch l.filesState {
		case logFilesIdle:
			a.logEmpty(f, g.SelectCommit)
			return
		case logFilesLoading:
			a.logEmpty(f, g.LoadingFiles)
			return
		case logFilesFailed:
			f.Column().Fill().Center().Gap(8).Children(func() {
				f.Text(g.FilesFailed).Color(a.colors.Subtle)
				if f.Button(logRetryFiles, g.Retry).Ghost().Clicked() {
					a.selectCommit(p, l.selected)
				}
			})
			return
		}
		if len(l.files) == 0 {
			a.logEmpty(f, g.NoChangedFiles)
			return
		}
		a.collectLogFiles(p)
		// Names are never cut short: the column is as wide as the widest row, and the list
		// scrolls sideways to show the rest of it, as the project tree does.
		var result treelist.Result
		f.Column().Fill().Children(func() {
			result = logFileList.Draw(f, &a.view, v.fileRows, v.fileSelected, treelist.Options{
				Dark:     a.colors.Dark,
				Expand:   i18n.Shared(a.language(), "native.expandDirectory"),
				Collapse: i18n.Shared(a.language(), "native.collapseDirectory"),
				Width:    max(v.fileScroll.Content, v.fileScroll.Viewport()),
				OffsetX:  v.fileScroll.Offset,
			}, func(i int) { a.drawLogFileContent(f, p, v.fileItems[i]) })
			a.drawSidewaysThumb(f, logFilesScrollbar, &v.fileScroll, false)
		})
		v.fileArea, v.filesDrawn = result.Area, true
		if i := result.Clicked; i >= 0 {
			l.listFocus = false
			a.selectLogFileRow(p, i)
		}
		if i := result.Toggled; i >= 0 {
			l.listFocus = false
			a.selectLogFileRow(p, i)
			a.toggleLogFolder(p, v.fileItems[i].folder)
		}
	})
}

// logFileItem is what a row of the changed files is: the folder of the commit's folders at
// index folder, or the file at index file of the commit's files; file is -1 for a folder.
type logFileItem struct {
	folder, file int
}

// collectLogFiles lists the rows of the changed files the way they show: each folder, but
// the top of the repository, as a row of its own, and the files of the open ones under them.
func (a *App) collectLogFiles(p *project) {
	l, v := &p.log, &a.logView
	v.fileRows, v.fileItems, v.fileSelected = v.fileRows[:0], v.fileItems[:0], -1
	for g, folder := range l.folders {
		depth := 0
		if folder.dir != "." {
			open := !l.closedFolders[folder.dir]
			if v.folder == folder.dir {
				v.fileSelected = len(v.fileRows)
			}
			v.fileRows = append(v.fileRows, treelist.Row{Key: g, Label: folder.dir, Branch: true, Expanded: open})
			v.fileItems = append(v.fileItems, logFileItem{folder: g, file: -1})
			if !open {
				continue
			}
			depth = 1
		}
		for _, i := range folder.files {
			file := l.files[i].Path
			if v.file == file {
				v.fileSelected = len(v.fileRows)
			}
			v.fileRows = append(v.fileRows, treelist.Row{Key: len(l.folders) + i, Label: file, Depth: depth})
			v.fileItems = append(v.fileItems, logFileItem{folder: g, file: i})
		}
	}
}

// logFileStatus is the width of the letter of a changed file's change, before its icon.
const logFileStatus = 14

// drawLogFileContent declares what a row of the changed files shows after its arrow: a
// folder's icon and path, or a file's change, icon and name in the color of its change.
// Names are laid out whole; captureLogFiles measures them the same way.
func (a *App) drawLogFileContent(f *ui.Frame, p *project, item logFileItem) {
	l := &p.log
	if item.file < 0 {
		dir := l.folders[item.folder].dir
		f.Icon(fileicons.ForDirectory(path.Base(dir), a.colors.Dark)).Size(treelist.Icon, treelist.Icon).Shrink(0).Color(a.colors.Subtle)
		f.Text(dir).FontSize(treeFontSize).Color(treelist.Text(a.colors.Dark)).Shrink(0)
		return
	}
	file := l.files[item.file]
	color := a.fileStatusColor(file.Status)
	f.Text(statusLetter(file.Status)).Mono().FontSize(a.theme.Metrics.FontSizeS).Color(color).Width(logFileStatus).Shrink(0)
	f.Icon(fileicons.ForFile(path.Base(file.Path), a.colors.Dark)).Size(treelist.Icon, treelist.Icon).Shrink(0).Color(a.colors.Subtle)
	f.Text(path.Base(file.Path)).FontSize(treeFontSize).Color(color).Shrink(0)
}

// captureLogFiles reads what the frame just laid out for the changed files: how wide their
// widest row is and how wide their list, keeping the sideways scroll in range. The rows are
// measured again only when they, the commit or the font change; another commit starts
// scrolled to the left.
func (a *App) captureLogFiles(canvas *gfx.Canvas) {
	v := &a.logView
	if !v.filesDrawn || a.project == nil {
		v.fileScroll.Area = gfx.Rect{}
		return
	}
	v.filesDrawn = false
	l := &a.project.log
	width := v.fileScroll.Content
	font := float32(treeFontSize)
	same := slices.EqualFunc(v.fileWidthKeys, v.fileRows, func(key int, row treelist.Row) bool { return key == row.Key })
	if v.fileWidthOf != l.selected || v.fileWidthFont != font || !same {
		if v.fileWidthOf != l.selected {
			v.fileScroll.Offset = 0
		}
		width = 0
		for i, row := range v.fileRows {
			item := v.fileItems[i]
			if item.file < 0 {
				name := canvas.TextWidthWeight(l.folders[item.folder].dir, font, gfx.WeightRegular)
				width = max(width, treelist.Width(row.Depth, treelist.Icon+treelist.Gap+name))
				continue
			}
			name := canvas.TextWidthWeight(path.Base(l.files[item.file].Path), font, gfx.WeightRegular)
			width = max(width, treelist.Width(row.Depth, logFileStatus+treelist.Gap+treelist.Icon+treelist.Gap+name))
		}
		width += treeScrollPad
		v.fileWidthKeys = v.fileWidthKeys[:0]
		for _, row := range v.fileRows {
			v.fileWidthKeys = append(v.fileWidthKeys, row.Key)
		}
		v.fileWidthOf, v.fileWidthFont = l.selected, font
	}
	if v.fileScroll.Fit(v.fileArea.Rect(), width) {
		canvas.RequestFrame()
	}
}

// selectLogFileRow selects the folder or the file of row i of the changed files.
func (a *App) selectLogFileRow(p *project, i int) {
	v, item := &a.logView, a.logView.fileItems[i]
	if item.file < 0 {
		v.file, v.folder = "", p.log.folders[item.folder].dir
	} else {
		v.file, v.folder = p.log.files[item.file].Path, ""
	}
}

// toggleLogFolder closes the folder at index g of the changed files when it is open and opens
// it when it is closed. A selected file the folder closes over passes the selection, and the
// keyboard, to the folder.
func (a *App) toggleLogFolder(p *project, g int) {
	l, v := &p.log, &a.logView
	dir := l.folders[g].dir
	if l.closedFolders[dir] {
		delete(l.closedFolders, dir)
		return
	}
	if l.closedFolders == nil {
		l.closedFolders = map[string]bool{}
	}
	l.closedFolders[dir] = true
	if v.file != "" && path.Dir(v.file) == dir {
		v.file, v.folder = "", dir
		v.focus = logFileRows.At(g)
	}
}

// logFilesKey gives a key pressed on a row of the changed files to their tree: the arrows
// move between the rows and open and close the folders, and Enter opens or closes a folder.
// The rows are listed again from the commit's files, as the key may come before the frame
// that shows a change to them. The second result says whether the key was the tree's.
func (a *App) logFilesKey(p *project, event gfx.KeyEvent) (gfx.EventResult, bool) {
	if !p.log.showDetails {
		return gfx.EventResult{}, false
	}
	v := &a.logView
	a.collectLogFiles(p)
	action, i, ok := logFileList.Key(event, &a.view, v.fileRows, v.fileSelected)
	if !ok {
		return gfx.EventResult{}, false
	}
	switch action {
	case treelist.Select:
		a.selectLogFileRow(p, i)
		v.focus = logFileRows.At(v.fileRows[i].Key)
	case treelist.Expand, treelist.Collapse:
		a.selectLogFileRow(p, i)
		a.toggleLogFolder(p, v.fileItems[i].folder)
	case treelist.Activate:
		if v.fileItems[i].file >= 0 {
			return gfx.EventResult{Handled: true}, true
		}
		a.selectLogFileRow(p, i)
		a.toggleLogFolder(p, v.fileItems[i].folder)
	default:
		return gfx.EventResult{Handled: true}, true
	}
	return gfx.EventResult{Handled: true, Repaint: true}, true
}

// logFilesPointer opens or closes a folder of the changed files on a double click on its
// row; the click before it selected the folder. The second result says whether the event was
// the tree's.
func (a *App) logFilesPointer(event gfx.PointerEvent) (gfx.EventResult, bool) {
	p := a.project
	if p == nil || a.layout.gitTab != 0 || !p.log.showDetails {
		return gfx.EventResult{}, false
	}
	key, ok := logFileList.DoubleClicked(event)
	if !ok {
		return gfx.EventResult{}, false
	}
	v := &a.logView
	a.collectLogFiles(p)
	i := treelist.Index(v.fileRows, key)
	if i < 0 || v.fileItems[i].file >= 0 {
		return gfx.EventResult{}, false
	}
	a.selectLogFileRow(p, i)
	a.toggleLogFolder(p, v.fileItems[i].folder)
	return gfx.EventResult{Handled: true, Repaint: true}, true
}

// statusLetter is the one letter Git gives a file's change.
func statusLetter(status string) string {
	if status == "" {
		return "?"
	}
	return strings.ToUpper(status[:1])
}

func (a *App) fileStatusColor(status string) gfx.Color {
	switch statusLetter(status) {
	case "A":
		return a.colors.Success
	case "D":
		return a.colors.Deleted
	case "M", "R", "C":
		return a.colors.Accent
	}
	return a.colors.Text
}

// drawLogCommitDetail declares the details of the selected commit.
func (a *App) drawLogCommitDetail(f *ui.Frame, p *project) ui.Box {
	l, g := &p.log, a.text.Git
	return f.Column().FillWidth().Clip().Children(func() {
		f.Divider()
		if l.selected == "" {
			a.logEmpty(f, g.SelectCommit)
			return
		}
		if l.detail == nil {
			if l.filesState == logFilesLoading {
				a.logEmpty(f, g.LoadingFiles)
			}
			return
		}
		d := l.detail
		var labels []core.GraphLabel
		for _, row := range l.graph.Rows {
			if row.CommitHash == l.selected {
				labels = row.Labels
				break
			}
		}
		f.ScrollArea(logDetailID).Grow(1).Pad(logDetailPad).Gap(8).Children(func() {
			f.Column().FillWidth().Children(func() {
				for _, line := range a.logView.subjectLines(f.Canvas(), d.Commit.Subject) {
					f.Text(line).Mono().Bold().FontSize(logFontSize).FillWidth()
				}
			})
			a.drawLogMeta(f, d)
			if chips := slices.DeleteFunc(slices.Clone(labels), func(x core.GraphLabel) bool { return x.Kind == "head" }); len(chips) > 0 {
				// Viva has no wrapping row, so the chips are broken into lines here, each line
				// a row of the chips that fit it whole.
				starts := a.logView.refRows(f.Canvas(), chips, a.theme.Metrics.FontSizeS)
				f.Column().FillWidth().Gap(logRefChipGap).Children(func() {
					for line, start := range starts {
						end := len(chips)
						if line+1 < len(starts) {
							end = starts[line+1]
						}
						f.Row().FillWidth().Gap(logRefChipGap).Clip().Children(func() {
							for _, label := range chips[start:end] {
								a.drawLogRefChip(f, label)
							}
						})
					}
				})
			}
			if body := strings.TrimSpace(d.Body); body != "" {
				f.Wrap(body).FontSize(logMetaSize)
			}
		})
	})
}

// subjectLines is subject broken into the lines the commit details draw it in, monospaced and
// bold. A ui Wrap breaks a Mono text where the proportional font fills the line, so its
// lines would run past the pane and lose their ends. The lines are kept until the subject,
// the width of the details or the fonts change.
func (v *logView) subjectLines(canvas *gfx.Canvas, subject string) []string {
	width := v.detailWidth - 2*logDetailPad
	if fonts := canvas.FontGeneration(); subject != v.subjectOf || width != v.subjectWidth || fonts != v.subjectFonts {
		style := gfx.TextStyle{Size: logFontSize, Weight: gfx.WeightSemibold, Mono: true}
		v.subject = monogrid.Lines(canvas, v.subject[:0], subject, style, width)
		v.subjectOf, v.subjectWidth, v.subjectFonts = subject, width, fonts
	}
	return v.subject
}

// refRows is where the lines of reference chips start when the commit details wrap labels,
// drawn at font size size: the index of the first chip of each line. Each chip is measured
// as drawLogRefChip lays it out, and the lines are as wide as subjectLines breaks the
// subject at, the details less their padding; the details pane is given exactly
// detailWidth, so the width is known before the frame is laid out. A line holds the chips
// that fit it whole, so none is cut off by the pane's edge, and a chip wider than a line
// has one to itself. Without a canvas to measure with the chips stay in one line.
func (v *logView) refRows(canvas *gfx.Canvas, labels []core.GraphLabel, size float32) []int {
	avail := v.detailWidth - 2*logDetailPad
	v.refWidths = v.refWidths[:0]
	if canvas == nil || avail <= 0 {
		v.refStarts = append(v.refStarts[:0], 0)
		return v.refStarts
	}
	for _, label := range labels {
		width := 2*logRefChipPad + logRefIconSize + logRefChipGap + canvas.TextWidth(label.Title, size)
		v.refWidths = append(v.refWidths, width)
	}
	v.refStarts = wrapTabs(v.refStarts[:0], v.refWidths, avail, logRefChipGap)
	return v.refStarts
}

// drawLogMeta declares the author line of commit d's details: the short hash, the author,
// the email and the date. None of them is cut short. The parts wrap onto more lines when the
// details are narrow, as metaRows breaks them, and a part wider than a line, such as a long
// email, has one to itself and breaks inside it as a ui Wrap does. The short hash is a few
// characters, so the fixed-pitch part never needs breaking.
func (a *App) drawLogMeta(f *ui.Frame, d *core.GitCommitDetail) {
	v := &a.logView
	muted := a.theme.MutedForeground
	parts := append(v.metaParts[:0],
		logMetaPart{text: d.Commit.ShortHash, mono: true, color: muted},
		logMetaPart{text: d.Commit.AuthorName, color: a.theme.Foreground})
	if d.Commit.AuthorEmail != "" {
		parts = append(parts, logMetaPart{text: "<" + d.Commit.AuthorEmail + ">", color: a.colors.Accent})
	}
	parts = append(parts, logMetaPart{text: a.text.Git.On(v.date(d.Commit)), color: muted})
	v.metaParts = parts
	starts := v.metaRows(f.Canvas(), parts, a.theme.Metrics.FontSizeM)
	avail := v.detailWidth - 2*logDetailPad
	f.Column().FillWidth().Gap(logAuthorLineGap).Children(func() {
		for line, start := range starts {
			end := len(parts)
			if line+1 < len(starts) {
				end = starts[line+1]
			}
			if end-start == 1 && start < len(v.metaWidths) && v.metaWidths[start] > avail {
				f.Wrap(parts[start].text).FillWidth().Color(parts[start].color)
				continue
			}
			f.Row().FillWidth().Items(ui.Center).Gap(logAuthorGap).Children(func() {
				for _, part := range parts[start:end] {
					text := f.Text(part.text).Color(part.color).Shrink(0)
					if part.mono {
						text.Mono()
					}
				}
			})
		}
	})
}

// metaRows is where the lines of the author line's parts start when the commit details wrap
// it, drawn at font size size: the index of the first part of each line. Each part is
// measured in the font drawLogMeta draws it in and rounded up to a whole point, so a line
// that fits by these numbers fits once laid out, and the lines are as wide as refRows wraps
// the reference chips at. A part wider than a line has one to itself. Without a canvas to
// measure with the parts stay in one line.
func (v *logView) metaRows(canvas *gfx.Canvas, parts []logMetaPart, size float32) []int {
	avail := v.detailWidth - 2*logDetailPad
	v.metaWidths = v.metaWidths[:0]
	if canvas == nil || avail <= 0 {
		v.metaStarts = append(v.metaStarts[:0], 0)
		return v.metaStarts
	}
	for _, part := range parts {
		width := canvas.TextWidthStyle(part.text, gfx.TextStyle{Size: size, Weight: gfx.WeightRegular, Mono: part.mono})
		v.metaWidths = append(v.metaWidths, float32(math.Ceil(float64(width))))
	}
	v.metaStarts = wrapTabs(v.metaStarts[:0], v.metaWidths, avail, logAuthorGap)
	return v.metaStarts
}

// drawLogRefChip declares one reference chip of the commit details, laid out with the
// numbers refRows measures it by. Its name is drawn whole unless the chip is wider than a
// line, which refRows gives it alone; then the chip gives way to the line and its name
// ends in an ellipsis.
func (a *App) drawLogRefChip(f *ui.Frame, label core.GraphLabel) {
	chip := f.Row().Height(logRefChipHeight).Shrink(1).Items(ui.Center).Gap(logRefChipGap).PadX(logRefChipPad).
		Radius(a.theme.Metrics.RadiusItem()).Background(a.colors.Hover)
	chip.Children(func() {
		f.Icon(icons.Tag).Size(logRefIconSize, logRefIconSize).Color(referenceColor(label.Kind, a.colors.Dark))
		f.Text(label.Title).FontSize(a.theme.Metrics.FontSizeS).Ellipsis()
	})
}

// toggleLogPopover opens a popover of the log tab, or closes it when it is open.
func (a *App) toggleLogPopover(p *project, which logPopover) {
	l, v := &p.log, &a.logView
	if l.popover == which {
		l.popover = logPopoverNone
		return
	}
	l.popover = which
	switch which {
	case logPopoverUser:
		v.userSearch.SetText("")
		v.focus = logUserSearchID
	case logPopoverPath:
		v.pathField.SetText(l.path)
		v.focus = logPathID
	}
}

// drawLogPopover declares the open popover of the log tab, over a backdrop that closes
// it when clicked.
func (a *App) drawLogPopover(f *ui.Frame, p *project) {
	l, v := &p.log, &a.logView
	if l.popover == logPopoverNone {
		return
	}
	anchor, align, width := ui.Box{}, ui.Start, float32(logPopoverWidth)
	switch l.popover {
	case logPopoverMenu:
		if !v.hasMenu {
			l.popover = logPopoverNone
			return
		}
		anchor, align = v.menu, ui.End
	case logPopoverBranch:
		anchor = v.chips[logChipBranch]
	case logPopoverUser:
		anchor = v.chips[logChipUser]
	case logPopoverDate:
		anchor = v.chips[logChipDate]
	case logPopoverPath:
		anchor, width = v.chips[logChipPath], logPathWidth
	}
	backdrop := f.Popup().At(0, 0).Fill().Hit(logDismiss, a.text.Errors.Dismiss)
	if backdrop.Clicked() {
		l.popover = logPopoverNone
		return
	}
	f.Popup().BelowBox(anchor, 4, align).Width(width).Pad(4).
		Background(a.theme.Popover).Border(1, a.theme.Border).Radius(a.theme.Metrics.RadiusPopup()).Shadow(gfx.ShadowMD).
		Children(func() {
			switch l.popover {
			case logPopoverMenu:
				a.drawLogMenu(f, p)
			case logPopoverBranch:
				a.drawLogBranchFilter(f, p)
			case logPopoverUser:
				a.drawLogUserFilter(f, p)
			case logPopoverDate:
				a.drawLogDateFilter(f, p)
			case logPopoverPath:
				a.drawLogPathFilter(f, p)
			}
		})
}

// drawLogMenu declares the items of the log tab's menu.
func (a *App) drawLogMenu(f *ui.Frame, p *project) {
	l, g := &p.log, a.text.Git
	unavailable := func() { a.notify(a.text.Welcome.Unavailable) }
	items := []struct {
		label    string
		disabled bool
		run      func()
	}{
		{g.FetchAll, false, unavailable},
		{g.FetchOptions, false, unavailable},
		{g.UpdateBranch, l.current == "", unavailable},
		{g.RefreshLog, false, func() { a.loadLog(p) }},
		{"", false, nil},
		{g.ShowChanges, false, unavailable},
	}
	for i, item := range items {
		if item.run == nil {
			f.Divider().PadY(4)
			continue
		}
		if a.logMenuItem(f, logItems.At(i), item.label, false, item.disabled) {
			l.popover = logPopoverNone
			item.run()
		}
	}
}

// drawLogBranchFilter declares the references the log can walk.
func (a *App) drawLogBranchFilter(f *ui.Frame, p *project) {
	l := &p.log
	f.ScrollArea(logBranchListID).FillWidth().MaxHeight(logListMaxHeight).Children(func() {
		n := 0
		if a.logMenuItem(f, logItems.At(n), a.text.Git.AllReferences, l.reference == "", false) {
			l.popover, l.refSelected = logPopoverNone, ""
			a.setLogReference(p, "", "")
		}
		n++
		for _, s := range l.sections[:2] {
			if len(s.refs) == 0 {
				continue
			}
			f.Divider().PadY(4)
			for _, r := range s.refs {
				if a.logMenuItem(f, logItems.At(n), r.ShortName, l.reference == r.FullName, false) {
					l.popover, l.refSelected = logPopoverNone, r.FullName
					a.setLogReference(p, r.FullName, r.ShortName)
				}
				n++
			}
		}
	})
}

// drawLogUserFilter declares the user filter: a search over the authors of the loaded
// commits.
func (a *App) drawLogUserFilter(f *ui.Frame, p *project) {
	l, v, g := &p.log, &a.logView, a.text.Git
	query := strings.ToLower(strings.TrimSpace(v.userSearch.Text()))
	f.Row().PadY(4).PadX(4).Children(func() {
		f.Field(&v.userSearch, logUserSearchID, g.SearchUsers, g.SearchUsers).Grow(1)
	})
	f.ScrollArea(logUserListID).FillWidth().MaxHeight(logListMaxHeight).Children(func() {
		n := 0
		if l.user != "" {
			if a.logMenuItem(f, logItems.At(n), g.ClearFilter, false, false) {
				a.setLogUser(p, "")
			}
			n++
		}
		shown := 0
		for _, user := range l.logUsers() {
			if query != "" && !strings.Contains(strings.ToLower(user), query) {
				continue
			}
			shown++
			if a.logMenuItem(f, logItems.At(n), user, l.user == user, false) {
				a.setLogUser(p, user)
			}
			n++
		}
		if shown == 0 {
			f.Text(g.NoMatchingUsers).Muted().TextCenter().FillWidth().PadY(12)
		}
	})
}

func (a *App) setLogUser(p *project, user string) {
	l := &p.log
	l.popover = logPopoverNone
	if l.user == user {
		return
	}
	l.user = user
	if !l.loading {
		a.reproject(p, 0)
	}
}

// drawLogDateFilter declares the date presets.
func (a *App) drawLogDateFilter(f *ui.Frame, p *project) {
	l, g := &p.log, a.text.Git
	labels := [logDateCount]string{g.AnyTime, g.Today, g.Yesterday, g.Last7Days, g.Last30Days}
	for d := logAnyTime; d < logDateCount; d++ {
		if a.logMenuItem(f, logItems.At(int(d)), labels[d], l.date == d, false) {
			l.popover = logPopoverNone
			if l.date != d {
				l.date = d
				if !l.loading {
					a.reproject(p, 0)
				}
			}
		}
	}
	if l.hasMore {
		f.Divider().PadY(4)
		f.Paragraph(g.OlderOutside, 3).Muted().FontSize(a.theme.Metrics.FontSizeS).PadX(8).PadY(4)
	}
}

// drawLogPathFilter declares the path filter: a field and the buttons that apply it.
func (a *App) drawLogPathFilter(f *ui.Frame, p *project) {
	l, v, g := &p.log, &a.logView, a.text.Git
	apply := func(value string) {
		l.popover = logPopoverNone
		value = strings.TrimSpace(value)
		if l.path == value {
			return
		}
		l.path = value
		if !l.loading {
			a.reproject(p, 0)
		}
	}
	f.Column().FillWidth().Pad(8).Gap(8).Children(func() {
		f.Text(g.PathTitle).Weight(gfx.WeightMedium)
		if f.Field(&v.pathField, logPathID, g.PathTitle, g.PathPlaceholder).FillWidth().Submitted() {
			apply(v.pathField.Text())
		}
		f.Row().FillWidth().Gap(8).Items(ui.Center).Children(func() {
			if f.Button(logPathClear, g.Clear).Ghost().Clicked() {
				v.pathField.SetText("")
				apply("")
			}
			f.Spacer()
			if f.Button(logPathCancel, g.Cancel).Secondary().Clicked() {
				l.popover = logPopoverNone
			}
			if f.Button(logPathApply, g.Apply).Clicked() {
				apply(v.pathField.Text())
			}
		})
	})
}

// logMenuItem declares one item of a popover, with a check mark when it is chosen, and
// reports a click on it.
func (a *App) logMenuItem(f *ui.Frame, id gfx.ID, label string, checked, disabled bool) bool {
	item := f.Row().Height(logItemHeight+2).FillWidth().Shrink(0).Items(ui.Center).Gap(8).PadX(8).
		Radius(a.theme.Metrics.RadiusItem()).
		HitWith(id, label, gfx.HitOptions{Role: gfx.RoleMenuItem}).Disabled(disabled)
	if !disabled {
		item = item.Hover(ui.Look{}.Background(a.colors.Hover)).Pressed(ui.Look{}.Background(a.colors.Active))
	}
	item.Children(func() {
		if checked {
			f.Icon(icons.Check).Size(14, 14).Color(a.colors.Accent)
		} else {
			f.Row().Size(14, 14).Shrink(0)
		}
		color := a.colors.Text
		if disabled {
			color = a.colors.Subtle
		}
		f.Text(label).Color(color).Ellipsis().Grow(1)
	})
	return !disabled && item.Clicked()
}

// logIconButton declares an icon button of the log tab and reports a click on it. on
// shows it pressed, for the buttons that toggle a view.
func (a *App) logIconButton(f *ui.Frame, id gfx.ID, label string, icon gfx.Icon, on, disabled bool) bool {
	return a.toolIconButton(f, id, label, icon, on, disabled, nil)
}
