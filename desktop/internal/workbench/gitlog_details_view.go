package workbench

import (
	"math"
	"path"
	"slices"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/fileicons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/monogrid"
	"github.com/1lck/Lithe-IDEA/desktop/internal/treelist"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// This file declares the details pane of the log tab: the files the selected commit changed,
// grouped by folder, over the commit's details.

// drawLogDetails declares the details pane: the changed files over the commit details.
func (a *App) drawLogDetails(c ui.C, p *project) ui.Box {
	v := &a.logView
	return ui.Column(c).FillHeight().Clip().Background(a.colors.Editor).Children(func() {
		a.drawLogFiles(c, p).Height(v.filesSplit.Pos).Shrink(0)
		ui.Splitter(c, &v.filesSplit).Mins(logFilesMin, logCommitMin).Label(a.text.Panel.Resize)
		a.drawLogCommitDetail(c, p).Grow(1)
	})
}

// drawLogFiles declares the files the selected commit changed, grouped by folder.
func (a *App) drawLogFiles(c ui.C, p *project) ui.Box {
	l, v, g := &p.log, &a.logView, a.text.Git
	if !slices.ContainsFunc(l.files, func(file core.GitCommitFile) bool { return file.Path == v.file }) {
		v.file = ""
	}
	if !slices.ContainsFunc(l.folders, func(folder logFolder) bool { return folder.dir == v.folder }) {
		v.folder = ""
	}
	return ui.Column(c).FillWidth().Clip().Children(func() {
		ui.Row(c).Height(logToolbarHeight).Shrink(0).Items(ui.Center).Gap(4).PadX(6).Children(func() {
			if a.gitIconButton(c, g.CompareChanges, icons.ArrowLeftRight, false, v.file == "") {
				c.After(func() { a.compareLogFile(p, v.file) })
			}
			if a.gitIconButton(c, g.FileHistory, icons.Clock, false, v.file == "") {
				c.After(func() { a.showLogFileHistory(p, v.file) })
			}
		})
		ui.Divider(c)
		switch l.filesState {
		case logFilesIdle:
			a.gitEmpty(c, g.SelectCommit)
			return
		case logFilesLoading:
			a.gitEmpty(c, g.LoadingFiles)
			return
		case logFilesFailed:
			ui.Column(c).Fill().Center().Gap(8).Children(func() {
				ui.Text(c, g.FilesFailed).Color(a.colors.Subtle)
				if ui.Button(c, g.Retry).Ghost().Clicked() {
					c.After(func() { a.selectCommit(p, l.selected) })
				}
			})
			return
		}
		if len(l.files) == 0 {
			a.gitEmpty(c, g.NoChangedFiles)
			return
		}
		a.drawLogFileList(c, p)
	})
}

// logFileRow is one row of the changed files: a folder, or a file in or under one. key names
// the row so the keyboard stays on an item as rows above it come and go: the index of the
// folder in the commit's folders, or the number of folders plus the index of the file in the
// commit's files.
type logFileRow struct {
	key              int
	label            string
	depth            int
	branch, expanded bool
	logFileItem
}

// logFileItem is what a row of the changed files is: the folder of the commit's folders at
// index folder, or the file at index file of the commit's files; file is -1 for a folder.
type logFileItem struct {
	folder, file int
}

// drawLogFileList declares the list of the changed files. Names are never cut short: the rows
// are as wide as the widest one, and the list scrolls sideways to show the rest of it, as the
// project tree does.
func (a *App) drawLogFileList(c ui.C, p *project) {
	v := &a.logView
	a.collectLogFiles(p)
	v.files.RowWidth = a.measureLogFiles(c.Canvas(), p)
	if v.files.Key == nil {
		v.files.Key, v.files.Label = v.fileKey, v.fileLabel
	}
	if !v.files.Changed() && v.files.Selected() != v.fileSelected {
		v.files.Select(v.fileSelected)
	}
	// The arrow keys are the list's container's, so they act while a row has the keyboard.
	pane := ui.Column(c).Grow(1).FillWidth().Children(func() {
		ui.List(c, &v.files, len(v.fileRows), func(row ui.ListRow) { a.drawLogFileRow(c, p, row) }).Grow(1).FillWidth()
	})
	if v.files.Changed() {
		if i := v.files.Selected(); i >= 0 && i < len(v.fileRows) {
			a.selectLogFileRow(p, i)
		}
	}
	if i, ok := v.files.Submitted(); ok && i >= 0 && i < len(v.fileRows) {
		if r := v.fileRows[i]; r.branch {
			c.After(func() { a.toggleLogFolder(p, r.folder) })
		} else if r.file >= 0 {
			file := p.log.files[r.file].Path
			c.After(func() { a.compareLogFile(p, file) })
		}
	}
	if pane.Shortcut(0, "right") {
		c.After(func() { a.stepLogFile(p, true) })
	}
	if pane.Shortcut(0, "left") {
		c.After(func() { a.stepLogFile(p, false) })
	}
}

// fileKey and fileLabel name the rows of the changed files to their list.
func (v *logView) fileKey(i int) int { return v.fileRows[i].key }

func (v *logView) fileLabel(i int) string { return v.fileRows[i].label }

// collectLogFiles lists the rows of the changed files the way they show: each folder, but
// the top of the repository, as a row of its own, and the files of the open ones under them.
func (a *App) collectLogFiles(p *project) {
	l, v := &p.log, &a.logView
	v.fileRows, v.fileSelected = v.fileRows[:0], -1
	for g, folder := range l.folders {
		depth := 0
		if folder.dir != "." {
			open := !l.closedFolders[folder.dir]
			if v.folder == folder.dir {
				v.fileSelected = len(v.fileRows)
			}
			v.fileRows = append(v.fileRows, logFileRow{key: g, label: folder.dir, branch: true, expanded: open, logFileItem: logFileItem{folder: g, file: -1}})
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
			v.fileRows = append(v.fileRows, logFileRow{key: len(l.folders) + i, label: file, depth: depth, logFileItem: logFileItem{folder: g, file: i}})
		}
	}
}

// drawLogFileRow declares one row of the changed files: its arrow or the room of one, and a
// folder's icon and path or a file's change, icon and name in the color of its change.
func (a *App) drawLogFileRow(c ui.C, p *project, row ui.ListRow) {
	l, v := &p.log, &a.logView
	r := v.fileRows[row.Index]
	box := row.Element.Height(treelist.RowHeight).Items(ui.Center).Gap(treelist.Gap).
		PadSides(0, treelist.Gutter+treelist.Trailing, 0, float32(treelist.Gutter+r.depth*treelist.Indent)).
		Radius(a.theme.Metrics.RadiusItem())
	if row.Index == v.fileSelected {
		box = box.Background(a.colors.Selection)
	} else {
		box = box.Hover(ui.Look{}.Background(a.colors.Hover))
	}
	box.Children(func() {
		a.drawLogFileArrow(c, p, r)
		if r.file < 0 {
			dir := l.folders[r.folder].dir
			ui.Icon(c, fileicons.ForDirectory(path.Base(dir), a.colors.Dark)).Size(treelist.Icon, treelist.Icon).Shrink(0).Color(a.colors.Subtle)
			ui.Text(c, dir).FontSize(treeFontSize).Color(treelist.Text(a.colors.Dark)).Shrink(0)
			return
		}
		file := l.files[r.file]
		color := a.fileStatusColor(file.Status)
		ui.Text(c, statusLetter(file.Status)).Mono().FontSize(a.theme.Metrics.FontSizeS).Color(color).Width(logFileStatus).Shrink(0)
		ui.Icon(c, fileicons.ForFile(path.Base(file.Path), a.colors.Dark)).Size(treelist.Icon, treelist.Icon).Shrink(0).Color(a.colors.Subtle)
		ui.Text(c, path.Base(file.Path)).FontSize(treeFontSize).Color(color).Shrink(0)
	})
}

// drawLogFileArrow declares the arrow that opens or closes a folder, or the room of one before
// a file, so a folder's files line up with its sub-folders.
func (a *App) drawLogFileArrow(c ui.C, p *project, r logFileRow) {
	slot := ui.Row(c.Part("arrow")).Size(treelist.Disclosure, treelist.Icon).Shrink(0).Center()
	if !r.branch {
		return
	}
	name := i18n.Shared(a.language(), "native.collapseDirectory")
	chevron := icons.ChevronDown
	if !r.expanded {
		name = i18n.Shared(a.language(), "native.expandDirectory")
		chevron = icons.ChevronRight
	}
	slot = slot.HitWith(ui.ID(c), name+" "+r.label, gfx.HitOptions{Role: gfx.RoleButton, Cursor: gfx.PointerCursorHand, Expandable: true, Expanded: r.expanded, SkipFocus: true})
	slot.Children(func() {
		ui.Icon(c, chevron).Size(12, 12).Color(a.colors.Subtle)
	})
	if slot.Clicked() {
		c.After(func() {
			a.selectLogFileRow(p, a.logFileIndex(r.key))
			a.toggleLogFolder(p, r.folder)
		})
	}
}

// logFileIndex is the index of the row with key among the changed files' rows, or 0 when it is
// gone.
func (a *App) logFileIndex(key int) int {
	return max(slices.IndexFunc(a.logView.fileRows, func(r logFileRow) bool { return r.key == key }), 0)
}

// logFileStatus is the width of the letter of a changed file's change, before its icon.
const logFileStatus = 14

// measureLogFiles is how wide the widest row of the changed files is: the width the list's
// rows are given so that every name shows whole. The rows are measured again only when they,
// the commit or the font change; another commit starts scrolled to the left.
func (a *App) measureLogFiles(canvas *gfx.Canvas, p *project) float32 {
	l, v := &p.log, &a.logView
	font := float32(treeFontSize)
	same := slices.EqualFunc(v.fileWidthKeys, v.fileRows, func(key int, row logFileRow) bool { return key == row.key })
	if v.fileWidthOf == l.selected && v.fileWidthFont == font && same {
		return v.fileWidth
	}
	if v.fileWidthOf != l.selected {
		v.files.ScrollToX(0)
	}
	width := float32(0)
	for _, row := range v.fileRows {
		if row.file < 0 {
			name := canvas.TextWidthWeight(l.folders[row.folder].dir, font, gfx.WeightRegular)
			width = max(width, treelist.Width(row.depth, treelist.Icon+treelist.Gap+name))
			continue
		}
		name := canvas.TextWidthWeight(path.Base(l.files[row.file].Path), font, gfx.WeightRegular)
		width = max(width, treelist.Width(row.depth, logFileStatus+treelist.Gap+treelist.Icon+treelist.Gap+name))
	}
	v.fileWidth = width + treeScrollPad
	v.fileWidthKeys = v.fileWidthKeys[:0]
	for _, row := range v.fileRows {
		v.fileWidthKeys = append(v.fileWidthKeys, row.key)
	}
	v.fileWidthOf, v.fileWidthFont = l.selected, font
	return v.fileWidth
}

// compareLogFile opens the diff of what the selected commit changed in file.
func (a *App) compareLogFile(p *project, file string) {
	l := &p.log
	i := slices.IndexFunc(l.files, func(f core.GitCommitFile) bool { return f.Path == file })
	if l.selected == "" || i < 0 {
		return
	}
	a.openCommitDiff(p, p.git.repositoryRoot(p.root), l.selected, l.files[i])
}

// showLogFileHistory narrows the log to the commits that changed file.
func (a *App) showLogFileHistory(p *project, file string) {
	l, v := &p.log, &a.logView
	if file == "" {
		return
	}
	a.performed("git.log.fileHistory", surfaceButton)
	l.path = file
	v.pathField.SetText(file)
	if !l.loading {
		a.reproject(p, 0)
	}
}

// selectLogFileRow selects the folder or the file of row i of the changed files.
func (a *App) selectLogFileRow(p *project, i int) {
	v := &a.logView
	if i < 0 || i >= len(v.fileRows) {
		return
	}
	r := v.fileRows[i]
	if r.file < 0 {
		v.file, v.folder = "", p.log.folders[r.folder].dir
	} else {
		v.file, v.folder = p.log.files[r.file].Path, ""
	}
}

// toggleLogFolder closes the folder at index g of the changed files when it is open and opens
// it when it is closed. A selected file the folder closes over passes the selection to the
// folder.
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
	}
}

// stepLogFile moves the selection of the changed files as Right and Left do in a tree: Right
// opens a closed folder and steps into an open one, Left closes an open folder and goes to the
// folder of a file or of a closed folder.
func (a *App) stepLogFile(p *project, right bool) {
	v := &a.logView
	a.collectLogFiles(p)
	i := v.fileSelected
	if i < 0 {
		return
	}
	r := v.fileRows[i]
	switch {
	case right && r.branch && !r.expanded:
		a.toggleLogFolder(p, r.folder)
	case right && r.branch && i+1 < len(v.fileRows):
		a.selectLogFileRow(p, i+1)
		v.files.Select(i + 1)
		v.files.ScrollIntoView(i + 1)
	case !right && r.branch && r.expanded:
		a.toggleLogFolder(p, r.folder)
	case !right && r.depth > 0:
		for j := i - 1; j >= 0; j-- {
			if v.fileRows[j].branch {
				a.selectLogFileRow(p, j)
				v.files.Select(j)
				v.files.ScrollIntoView(j)
				break
			}
		}
	}
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
func (a *App) drawLogCommitDetail(c ui.C, p *project) ui.Box {
	l, g := &p.log, a.text.Git
	return ui.Column(c).FillWidth().Clip().Children(func() {
		ui.Divider(c)
		if l.selected == "" {
			a.gitEmpty(c, g.SelectCommit)
			return
		}
		if l.detail == nil {
			if l.filesState == logFilesLoading {
				a.gitEmpty(c, g.LoadingFiles)
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
		ui.Scroll(c).Grow(1).Pad(logDetailPad).Gap(8).Children(func() {
			ui.Column(c).FillWidth().Children(func() {
				for i, line := range a.logView.subjectLines(c.Canvas(), d.Commit.Subject) {
					ui.Text(c.KeyInt(i), line).Mono().Bold().FontSize(logFontSize).FillWidth()
				}
			})
			a.drawLogMeta(c, d)
			if chips := slices.DeleteFunc(slices.Clone(labels), func(x core.GraphLabel) bool { return x.Kind == "head" }); len(chips) > 0 {
				// Viva has no wrapping row, so the chips are broken into lines here, each line
				// a row of the chips that fit it whole.
				starts := a.logView.refRows(c.Canvas(), chips, a.theme.Metrics.FontSizeS)
				ui.Column(c).FillWidth().Gap(logRefChipGap).Children(func() {
					for line, start := range starts {
						end := len(chips)
						if line+1 < len(starts) {
							end = starts[line+1]
						}
						ui.Row(c.KeyInt(line)).FillWidth().Gap(logRefChipGap).Clip().Children(func() {
							for _, label := range chips[start:end] {
								a.drawLogRefChip(c, label)
							}
						})
					}
				})
			}
			if body := strings.TrimSpace(d.Body); body != "" {
				ui.Wrap(c, body).FontSize(logMetaSize)
			}
		})
	})
}

// subjectLines is subject broken into the lines the commit details draw it in, monospaced and
// bold. A ui Wrap breaks a Mono text where the proportional font fills the line, narrower
// than the cells a Mono line is drawn on, so its lines would run past the pane and lose
// their ends. The lines are kept until the subject, the width of the details or the fonts
// change.
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
// detailWidth, so the width is known before the page is laid out. A line holds the chips
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
func (a *App) drawLogMeta(c ui.C, d *core.GitCommitDetail) {
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
	starts := v.metaRows(c.Canvas(), parts, a.theme.Metrics.FontSizeM)
	avail := v.detailWidth - 2*logDetailPad
	ui.Column(c).FillWidth().Gap(logAuthorLineGap).Children(func() {
		for line, start := range starts {
			end := len(parts)
			if line+1 < len(starts) {
				end = starts[line+1]
			}
			if end-start == 1 && start < len(v.metaWidths) && v.metaWidths[start] > avail {
				ui.Wrap(c.KeyInt(line), parts[start].text).FillWidth().Color(parts[start].color)
				continue
			}
			ui.Row(c.KeyInt(line)).FillWidth().Items(ui.Center).Gap(logAuthorGap).Children(func() {
				for _, part := range parts[start:end] {
					text := ui.Text(c, part.text).Color(part.color).Shrink(0)
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
func (a *App) drawLogRefChip(c ui.C, label core.GraphLabel) {
	chip := ui.Row(c.Key(label.ID)).Height(logRefChipHeight).Shrink(1).Items(ui.Center).Gap(logRefChipGap).PadX(logRefChipPad).
		Radius(a.theme.Metrics.RadiusItem()).Background(a.colors.Hover)
	chip.Children(func() {
		ui.Icon(c, icons.Tag).Size(logRefIconSize, logRefIconSize).Color(referenceColor(label.Kind, a.colors.Dark))
		ui.Text(c, label.Title).FontSize(a.theme.Metrics.FontSizeS).Ellipsis()
	})
}
