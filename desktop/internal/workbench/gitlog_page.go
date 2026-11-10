package workbench

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// The identities of the log page's fields, named in the page's own scope so that the
// window's input routing finds them as the page's (Page.Owns) and a focus request can reach
// them.
var (
	logPage         = tree.Feature("git-log")
	logSearchID     = tree.ID(logPage, "search")
	logRefSearchID  = tree.ID(logPage, "ref-search")
	logUserSearchID = tree.ID(logPage, "user-search")
	logPathID       = tree.ID(logPage, "path")
)

// The log tab of the Git tool window is one Page drawn into the room the tool window leaves
// under its header: the action stripe of the reference pane, the reference pane, the commit
// list with its filter bar, and the details pane with the changed files over the commit
// details. gitlog_view.go declares the layout, gitlog_details_view.go the details and
// gitlog_popover_view.go the popovers; gitgraph.go paints the rows of the commit list.

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
	// logRowSlots is how many rows of the commit list can be on screen at once, and so how
	// many draw callbacks the list keeps: a row uses the one of its index modulo the slots.
	logRowSlots = 256
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

// The filter chips of the commit list, for logView.chips.
const (
	logChipBranch = iota
	logChipUser
	logChipDate
	logChipPath
	logChipCount
)

// logView is the window's state of the log tab that is not the project's: the Page, the
// fields, the splitters, the lists, and what the page declared for the capture after it is
// drawn.
type logView struct {
	search, refSearch, userSearch, pathField ui.Field

	refSplit, detailSplit, filesSplit ui.SplitterState
	// detailWidth is the chosen width of the details pane; the commit list takes what
	// is left, so the details keep their width when the tool window is resized.
	detailWidth float32
	// bodyWidth is the width the commit list and the details shared in the last paint, and
	// derived the detail splitter's position that paint was declared with.
	bodyWidth, derived float32

	// bodyRect is where the commit list and the details were laid out in the last paint, read
	// from the draw callback bodyDraw gave their box. hasBody says the box was declared.
	bodyRect ui.Rect
	bodyDraw func(*ui.DrawContext)
	hasBody  bool
	details  bool

	// refs is the tree of the reference pane, refItems what its visible rows are and refSel
	// the reference selected in it, as the paint being drawn has it.
	refs     ui.TreeState
	refItems []logRefRow
	refSel   string
	// refLabel names the rows of refs, made once because a method value made in each paint
	// allocates.
	refLabel func(int) string
	// commits is the commit list; slotRow is the row each draw slot paints and painters the
	// callbacks that paint them.
	commits  ui.ListState
	slotRow  [logRowSlots]int
	painters [logRowSlots]func(*ui.DrawContext)

	// focus is the field to give the keyboard to in the next paint.
	focus gfx.ID

	// subject is the selected commit's subject broken into the lines the commit details draw
	// it in: subjectOf, in the details subjectWidth wide, with the fonts of subjectFonts.
	subject      []string
	subjectOf    string
	subjectWidth float32
	subjectFonts uint32
	// refWidths are the widths refRows measured the selected commit's reference chips at, and
	// refStarts the index of the first chip of each line they wrap onto; both are kept so the
	// next paint reuses their arrays.
	refWidths []float32
	refStarts []int
	// metaParts are the parts of the selected commit's author line, metaWidths the widths
	// metaRows measured them at, and metaStarts the index of the first part of each line
	// they wrap onto; all are kept so the next paint reuses their arrays.
	metaParts  []logMetaPart
	metaWidths []float32
	metaStarts []int

	// file is the path of the selected changed file, and folder the path of the selected
	// folder of the changed files; at most one of them is set.
	file, folder string
	// files is the list of the changed files, fileRows the rows it shows and fileSelected
	// the index of the selected one, -1 for none. fileWidthKeys, fileWidthOf and
	// fileWidthFont are the rows, the commit and the font size files.RowWidth was measured
	// for, and fileWidth that width.
	files         ui.ListState
	fileRows      []logFileRow
	fileSelected  int
	fileWidth     float32
	fileWidthKeys []int
	fileWidthOf   string
	fileWidthFont float32

	colors       map[int32]gfx.Color
	colorsDark   bool
	dates        map[string]string
	upstream     map[string]string
	upstreamFor  *logSection
	upstreamRefs int
	// dateWidth is the width of the date column, measured for fonts dateFonts.
	dateWidth float32
	dateFonts uint32
}

func newLogView() logView {
	v := logView{detailWidth: logDetailsWidth}
	v.refSplit.Pos = logRefsWidth
	v.filesSplit.Pos = logFilesHeight
	v.refs.RowHeight, v.refs.Indent = logItemHeight, logIndent
	return v
}

// reset empties the fields and the lists for a project that was just opened.
func (v *logView) reset() {
	for _, field := range []*ui.Field{&v.search, &v.refSearch, &v.userSearch, &v.pathField} {
		field.SetText("")
	}
	v.file, v.folder = "", ""
	v.dates = nil
	v.upstream = nil
	v.commits = ui.ListState{Label: v.commits.Label}
	v.files = ui.ListState{}
	v.refs.ListState = ui.ListState{}
}

// capture keeps the width the commit list and the details shared, and takes a drag of the
// detail splitter as a new width of the details.
func (v *logView) capture() {
	if !v.hasBody {
		return
	}
	width := v.bodyRect.Width
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

// splitKey gives a key to the splitter of the log tab that has the keyboard: a Page does not
// route a splitter's arrows, so the window forwards them.
func (v *logView) splitKey(event gfx.KeyEvent) gfx.EventResult {
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
	return gfx.EventResult{}
}

// logCommitLabel is the accessible name and type-ahead text of row i of the commit list: the
// subject of its commit.
func (a *App) logCommitLabel(i int) string {
	p := a.project
	if p == nil {
		return ""
	}
	rows := p.log.graph.Rows
	if i < 0 || i >= len(rows) {
		return ""
	}
	commit, _ := p.log.commit(rows[i].CommitHash)
	return commit.Subject
}

// rowPainter is the draw callback of row index of the commit list: it paints that row's graph,
// subject, author, date and reference labels into the row's rectangle. A callback is kept for
// each slot of logRowSlots rows, which index modulo the slots picks, so none is made in a paint.
func (v *logView) rowPainter(a *App, index int) func(*ui.DrawContext) {
	slot := index % logRowSlots
	v.slotRow[slot] = index
	if v.painters[slot] == nil {
		v.painters[slot] = func(d *ui.DrawContext) { a.paintLogRow(d.Canvas, d.Rect, v.slotRow[slot]) }
	}
	return v.painters[slot]
}

// logRefRow is one visible row of the reference pane: HEAD, the head of a section, a folder
// of a section's tree, or a reference.
type logRefRow struct {
	kind logRefKind
	// depth is the row's level in the tree.
	depth int
	label string
	// key is what a click on the row acts on: the key of the section or folder in
	// gitLogState.collapsed, or the full name of a reference.
	key string
	// short is a reference's short name, and ref the reference itself (nil for HEAD, which
	// stands for every reference).
	short string
	ref   *core.GitReference
	open  bool
}

// logRefKind is what a row of the reference pane is.
type logRefKind uint8

const (
	logRefHead logRefKind = iota
	logRefSection
	logRefFolder
	logRefReference
)
