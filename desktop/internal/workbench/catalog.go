package workbench

import (
	"context"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// zone is one place a rearrangeable button can sit in, in the order of the kernel's
// Zone constants. The tool stripes have six zones, the tool window anchors of the IDEA
// new UI: three on each stripe. The title bar and the status bar have one trailing zone
// each.
//
// Left Bottom and Bottom Left are two zones, and so are Right Bottom and Bottom Right.
// The first of each pair is the split group packed near the bottom of its stripe, directly
// above the bottom group, and opens in the lower half of the column beside the editor. The
// second is the bottom group packed at the stripe's end and opens in a half of the bottom
// area.
type zone uint8

const (
	// zoneLeftTop is the upper group of the left stripe.
	zoneLeftTop zone = iota
	// zoneLeftBottom is the left stripe's split group, above its bottom group.
	zoneLeftBottom
	// zoneBottomLeft is the group packed at the bottom of the left stripe.
	zoneBottomLeft
	// zoneRightTop is the upper group of the right stripe.
	zoneRightTop
	// zoneRightBottom is the right stripe's split group, above its bottom group.
	zoneRightBottom
	// zoneBottomRight is the group packed at the bottom of the right stripe.
	zoneBottomRight
	zoneTitle
	zoneStatus
	zoneCount
)

var zoneNames = [zoneCount]core.Zone{
	core.ZoneLeftTop, core.ZoneLeftBottom, core.ZoneBottomLeft,
	core.ZoneRightTop, core.ZoneRightBottom, core.ZoneBottomRight,
	core.ZoneTitleTrailing, core.ZoneStatusTrailing,
}

func zoneFromCore(name core.Zone) (zone, bool) {
	for z, candidate := range zoneNames {
		if candidate == name {
			return zone(z), true
		}
	}
	return 0, false
}

// surface is the bar a zone belongs to. A button never leaves its surface: a tool
// button moves among the six stripe zones, a title bar or status bar item only
// within its own bar.
type surface uint8

const (
	surfaceStripes surface = iota
	surfaceTitle
	surfaceStatus
)

func (z zone) surface() surface {
	switch z {
	case zoneTitle:
		return surfaceTitle
	case zoneStatus:
		return surfaceStatus
	}
	return surfaceStripes
}

// vertical reports whether the zone stacks its buttons top to bottom (the stripes)
// rather than left to right (the title bar and status bar).
func (z zone) vertical() bool { return z.surface() == surfaceStripes }

// slot is where the tool window of a stripe zone opens. Each stripe zone owns one
// slot, so the buttons of a zone share it and opening one closes the other.
type slot uint8

const (
	// slotLeftTop is the left column beside the editor, for zoneLeftTop; the top half of
	// the column while slotLeftBottom is open too.
	slotLeftTop slot = iota
	// slotLeftBottom is the lower half of the left column, for zoneLeftBottom; the whole
	// column while slotLeftTop is closed.
	slotLeftBottom
	// slotBottomLeft is the left half of the bottom area, for zoneBottomLeft; the whole
	// area while slotBottomRight is closed.
	slotBottomLeft
	// slotRightTop is the right column beside the editor, for zoneRightTop; the top half
	// of the column while slotRightBottom is open too.
	slotRightTop
	// slotRightBottom is the lower half of the right column, for zoneRightBottom; the
	// whole column while slotRightTop is closed.
	slotRightBottom
	// slotBottomRight is the right half of the bottom area, for zoneBottomRight; the
	// whole area while slotBottomLeft is closed.
	slotBottomRight
	slotCount
)

// slot returns the panel slot of a stripe zone.
func (z zone) slot() (slot, bool) {
	switch z {
	case zoneLeftTop:
		return slotLeftTop, true
	case zoneLeftBottom:
		return slotLeftBottom, true
	case zoneBottomLeft:
		return slotBottomLeft, true
	case zoneRightTop:
		return slotRightTop, true
	case zoneRightBottom:
		return slotRightBottom, true
	case zoneBottomRight:
		return slotBottomRight, true
	}
	return 0, false
}

// zone returns the stripe zone whose tool windows open in the slot.
func (s slot) zone() zone {
	switch s {
	case slotLeftBottom:
		return zoneLeftBottom
	case slotBottomLeft:
		return zoneBottomLeft
	case slotRightTop:
		return zoneRightTop
	case slotRightBottom:
		return zoneRightBottom
	case slotBottomRight:
		return zoneBottomRight
	}
	return zoneLeftTop
}

// Stable identifiers of the catalog items. They are persisted in the layout file, so
// a value never changes once released.
const (
	itemProject       = "project"
	itemCommit        = "commit"
	itemStructure     = "structure"
	itemFind          = "find"
	itemGit           = "git"
	itemTerminal      = "terminal"
	itemProblems      = "problems"
	itemReferences    = "references"
	itemRun           = "run"
	itemTests         = "tests"
	itemSecurity      = "security"
	itemDebug         = "debug"
	itemNotifications = "notifications"
	itemMarkdown      = "markdownPreview"
	itemUpdates       = "updates"
	itemBackground    = "background"

	itemRunConfig     = "title.runConfig"
	itemTitleRun      = "title.run"
	itemTitleDebug    = "title.debug"
	itemTitleSearch   = "title.search"
	itemTitleSettings = "title.settings"

	itemCaret    = "status.caret"
	itemLock     = "status.lock"
	itemLSP      = "status.lsp"
	itemVim      = "status.vim"
	itemEncoding = "status.encoding"
	itemIndent   = "status.indent"
	itemEOL      = "status.lineEnding"
	itemMemory   = "status.memory"
	itemFPS      = "status.fps"
	itemChanges  = "status.changes"
	itemHealth   = "status.health"
)

// item is one button the workbench can show in its rearrangeable chrome.
type item struct {
	id   string
	zone zone // the default zone; its surface is the only one the item may sit in
	// icon is the glyph of the button; nil for a status item that is text only.
	icon *gfx.Icon
	// label is the button's name, shown as its tooltip and read by assistive
	// technology.
	label func(*i18n.Messages) string
	// panel reports that the button opens a tool window in its zone's slot.
	panel bool
	// open reports that the tool window is open in the default layout.
	open bool
	// tool is the plugin tool window the item shows; nil for a built-in item.
	tool *pluginservice.ToolWindow
}

// catalog is every rearrangeable button, in the default order of each zone. The
// kernel owns the layout rules; this is only the host's list of what exists.
var catalog = []item{
	{id: itemProject, zone: zoneLeftTop, icon: &icons.Folder, label: func(m *i18n.Messages) string { return m.Tools.Project }, panel: true, open: true},
	{id: itemCommit, zone: zoneLeftTop, icon: &icons.GitCommitHorizontal, label: func(m *i18n.Messages) string { return m.Tools.Commit }, panel: true},
	{id: itemStructure, zone: zoneLeftTop, icon: &icons.ListTree, label: func(m *i18n.Messages) string { return m.Tools.Structure }, panel: true},
	{id: itemFind, zone: zoneLeftTop, icon: &icons.Search, label: func(m *i18n.Messages) string { return m.Tools.Find }, panel: true},

	{id: itemGit, zone: zoneBottomLeft, icon: &icons.GitBranch, label: func(m *i18n.Messages) string { return m.Tools.Git }, panel: true, open: true},
	{id: itemTerminal, zone: zoneBottomLeft, icon: &icons.SquareTerminal, label: func(m *i18n.Messages) string { return m.Tools.Terminal }, panel: true},
	{id: itemProblems, zone: zoneBottomLeft, icon: &icons.CircleAlert, label: func(m *i18n.Messages) string { return m.Tools.Problems }, panel: true},
	{id: itemReferences, zone: zoneBottomLeft, icon: &icons.Locate, label: func(m *i18n.Messages) string { return m.Tools.References }, panel: true},
	{id: itemRun, zone: zoneBottomLeft, icon: &icons.Play, label: func(m *i18n.Messages) string { return m.Tools.Build }, panel: true},
	{id: itemTests, zone: zoneBottomLeft, icon: &icons.CircleCheck, label: func(m *i18n.Messages) string { return m.Tools.Tests }, panel: true},
	{id: itemSecurity, zone: zoneBottomLeft, icon: &icons.ShieldCheck, label: func(m *i18n.Messages) string { return m.Tools.Security }, panel: true},
	{id: itemDebug, zone: zoneBottomLeft, icon: &icons.Bug, label: func(m *i18n.Messages) string { return m.Tools.Debug }, panel: true},

	{id: itemNotifications, zone: zoneRightTop, icon: &icons.Bell, label: func(m *i18n.Messages) string { return m.Tools.Notifications }, panel: true},
	{id: itemMarkdown, zone: zoneRightTop, icon: &icons.FileText, label: func(m *i18n.Messages) string { return m.Tools.MarkdownPreview }, panel: true},

	{id: itemUpdates, zone: zoneBottomRight, icon: &icons.RefreshCw, label: func(m *i18n.Messages) string { return m.Tools.Updates }, panel: true},
	{id: itemBackground, zone: zoneBottomRight, icon: &icons.Image, label: func(m *i18n.Messages) string { return m.Tools.Background }, panel: true},

	{id: itemRunConfig, zone: zoneTitle, icon: &icons.FileCode, label: func(m *i18n.Messages) string { return m.Title.RunConfiguration }},
	{id: itemTitleRun, zone: zoneTitle, icon: &icons.Play, label: func(m *i18n.Messages) string { return m.Title.Run }},
	{id: itemTitleDebug, zone: zoneTitle, icon: &icons.Bug, label: func(m *i18n.Messages) string { return m.Title.Debug }},
	{id: itemTitleSearch, zone: zoneTitle, icon: &icons.Search, label: func(m *i18n.Messages) string { return m.Title.Search }},
	{id: itemTitleSettings, zone: zoneTitle, icon: &icons.Settings, label: func(m *i18n.Messages) string { return m.Title.Settings }},

	{id: itemCaret, zone: zoneStatus, label: func(m *i18n.Messages) string { return m.Status.Caret }},
	{id: itemLock, zone: zoneStatus, icon: &icons.LockOpen, label: func(m *i18n.Messages) string { return m.Status.Writable }},
	{id: itemEncoding, zone: zoneStatus, label: func(m *i18n.Messages) string { return m.Status.Encoding }},
	{id: itemIndent, zone: zoneStatus, label: func(m *i18n.Messages) string { return m.Status.Indent }},
	{id: itemEOL, zone: zoneStatus, label: func(m *i18n.Messages) string { return m.Status.LineEnding }},
	{id: itemLSP, zone: zoneStatus, label: func(m *i18n.Messages) string { return m.Status.LSPNotStarted }},
	{id: itemVim, zone: zoneStatus, label: func(m *i18n.Messages) string { return m.Status.Vim }},
	{id: itemMemory, zone: zoneStatus, label: func(m *i18n.Messages) string { return m.Status.Memory }},
	{id: itemFPS, zone: zoneStatus, label: func(m *i18n.Messages) string { return m.Status.FPS }},
	{id: itemChanges, zone: zoneStatus, label: func(m *i18n.Messages) string { return m.Status.NoChanges }},
	{id: itemHealth, zone: zoneStatus, icon: &icons.CircleCheck, label: func(m *i18n.Messages) string { return m.Status.Healthy }},
}

// catalogIndex finds a built-in item by its identifier. A window lists the built-in
// items first, at the indices of catalog, so the index is the same in every window.
var catalogIndex map[string]int

func init() {
	catalogIndex = make(map[string]int, len(catalog))
	for i, it := range catalog {
		catalogIndex[it.id] = i
	}
}

// chromeState is the current arrangement of the rearrangeable buttons, derived from
// the kernel's layout, plus where each button and zone was laid out in the last frame,
// which the drag gesture measures against.
type chromeState struct {
	layout core.ChromeLayout
	// catalog is the catalog of this window: the built-in items at the indices of the
	// package's catalog, then the tool windows of the enabled plugins. index finds an item
	// by its identifier, and coreItems is catalog in the kernel's terms, sent with every
	// layout call.
	catalog   []item
	index     map[string]int
	coreItems []core.ChromeItem
	// saved is the arrangement last read from or written to the layout file. It still
	// places the tool windows of plugins that are not enabled now, so they come back where
	// the user left them.
	saved core.ChromeLayout
	// items lists the catalog indices of each zone in display order.
	items [zoneCount][]int
	// open is the catalog index of the open tool window of each slot, -1 for none.
	open [slotCount]int

	// ids is the identity each button was declared with in the last paint, which the drag
	// maps its source back to a catalog index by.
	ids []gfx.ID
	// rects and zoneRects are where the buttons and zones were laid out in the last paint,
	// kept by draw hooks as the elements are painted; a zero rectangle means the button or
	// zone was not shown. rectHooks and zoneHooks are made once, because a closure made in
	// each paint allocates.
	rects     []gfx.Rect
	zoneRects [zoneCount]gfx.Rect
	rectHooks []func(*ui.DrawContext)
	zoneHooks [zoneCount]func(*ui.DrawContext)
}

func newChromeState() *chromeState {
	c := &chromeState{}
	c.setItems(catalog)
	for z := range c.zoneHooks {
		c.zoneHooks[z] = func(d *ui.DrawContext) { c.zoneRects[z] = d.Rect }
	}
	c.apply(defaultLayout())
	return c
}

// setItems makes items the catalog of the window. The arrangement still names the old
// items until the kernel repairs it against the new catalog and it is applied again.
func (c *chromeState) setItems(items []item) {
	c.catalog = items
	c.index = make(map[string]int, len(items))
	c.coreItems = make([]core.ChromeItem, len(items))
	for i, it := range items {
		c.coreItems[i] = core.ChromeItem{ID: it.id, DefaultZone: zoneNames[it.zone], Panel: it.panel, OpenByDefault: it.open}
		c.index[it.id] = i
	}
	c.ids = make([]gfx.ID, len(items))
	c.rects = make([]gfx.Rect, len(items))
	c.rectHooks = make([]func(*ui.DrawContext), len(items))
	for i := range c.rectHooks {
		c.rectHooks[i] = func(d *ui.DrawContext) { c.rects[i] = d.Rect }
	}
}

// withAbsent is layout with the saved places of plugin tool windows the catalog does not
// list now, which the kernel leaves out of every layout it returns.
func (c *chromeState) withAbsent(layout core.ChromeLayout) core.ChromeLayout {
	merged := core.ChromeLayout{
		Placements: append([]core.Placement(nil), layout.Placements...),
		Open:       append([]string(nil), layout.Open...),
	}
	for _, placement := range c.saved.Placements {
		if _, known := c.index[placement.ID]; !known && isPluginItem(placement.ID) {
			merged.Placements = append(merged.Placements, placement)
		}
	}
	for _, id := range c.saved.Open {
		if _, known := c.index[id]; !known && isPluginItem(id) {
			merged.Open = append(merged.Open, id)
		}
	}
	return merged
}

// restated is the arrangement to repair against a changed catalog: the saved one, which
// places the plugin tool windows the old catalog lacked where the user left them,
// completed with the places of the current one that were never saved.
func (c *chromeState) restated() core.ChromeLayout {
	if len(c.saved.Placements) == 0 {
		return c.layout
	}
	restated := core.ChromeLayout{
		Placements: append([]core.Placement(nil), c.saved.Placements...),
		Open:       append([]string(nil), c.saved.Open...),
	}
	saved := make(map[string]bool, len(c.saved.Placements))
	for _, placement := range c.saved.Placements {
		saved[placement.ID] = true
	}
	for _, placement := range c.layout.Placements {
		if !saved[placement.ID] {
			restated.Placements = append(restated.Placements, placement)
		}
	}
	return restated
}

// defaultLayout is the catalog's default arrangement. It is what the window shows when
// the kernel cannot be asked; every change still goes through the kernel.
func defaultLayout() core.ChromeLayout {
	var layout core.ChromeLayout
	for z := range zoneCount {
		for _, it := range catalog {
			if it.zone == z {
				layout.Placements = append(layout.Placements, core.Placement{ID: it.id, Zone: zoneNames[z]})
				if it.open {
					layout.Open = append(layout.Open, it.id)
				}
			}
		}
	}
	return layout
}

// apply makes layout the current arrangement. Placements of unknown items or zones are
// skipped; the kernel never returns them.
func (c *chromeState) apply(layout core.ChromeLayout) {
	c.layout = layout
	for z := range c.items {
		c.items[z] = c.items[z][:0]
	}
	for s := range c.open {
		c.open[s] = -1
	}
	for _, placement := range layout.Placements {
		index, known := c.index[placement.ID]
		z, valid := zoneFromCore(placement.Zone)
		if !known || !valid {
			continue
		}
		c.items[z] = append(c.items[z], index)
	}
	for _, id := range layout.Open {
		index, known := c.index[id]
		if !known {
			continue
		}
		if s, ok := c.zoneOf(index).slot(); ok {
			c.open[s] = index
		}
	}
}

// zoneOf returns the zone catalog item index sits in now.
func (c *chromeState) zoneOf(index int) zone {
	for z := range c.items {
		for _, candidate := range c.items[z] {
			if candidate == index {
				return zone(z)
			}
		}
	}
	return c.catalog[index].zone
}

// isOpen reports whether the tool window of catalog item index is open.
func (c *chromeState) isOpen(index int) bool {
	for _, open := range c.open {
		if open == index {
			return true
		}
	}
	return false
}

// beginFrame forgets where the previous paint laid the buttons and zones out, before a new
// one declares them afresh.
func (c *chromeState) beginFrame() {
	clear(c.rects)
	c.zoneRects = [zoneCount]gfx.Rect{}
}

// place records where the element declared for the button of catalog item index is laid out.
func (c *chromeState) place(index int, box ui.Box) ui.Box { return box.Draw(c.rectHooks[index]) }

// placeZone records where the element declared for a zone is laid out: the container its
// buttons are in, which is also where a dragged button can be dropped.
func (c *chromeState) placeZone(z zone, box ui.Box) { box.Draw(c.zoneHooks[z]) }

// layoutFile is the saved arrangement of the rearrangeable buttons. The "v2" is there
// because the first version had four zones and its "leftBottom" and "rightBottom" meant
// what zoneBottomLeft and zoneBottomRight mean now; reading such a file with the six
// zones would silently move the buttons to the wrong anchors, so the old file is left
// alone and the default layout applies.
const layoutFile = "workbench-layout-v2.json"

// kernelCallTimeout bounds the kernel's pure computations, which answer in well under a
// millisecond; it only guards against a wedged kernel.
const kernelCallTimeout = 2 * time.Second

// loadChrome reads the saved layout and repairs it against the catalog through the
// kernel. A missing file is the default layout; an unreadable one is reported and
// replaced by the default layout on the next change.
func (a *App) loadChrome() {
	var saved core.ChromeLayout
	found, err := a.store.Load(layoutFile, &saved)
	if err != nil {
		a.notifyError(a.text.Errors.Core(err.Error()))
		saved, found = core.ChromeLayout{}, false
	}
	a.chrome.saved = saved
	// Normalizing keeps the saved open list, and an empty one means every tool window
	// is closed. With nothing saved the kernel's defaults apply, open windows included.
	action := core.NormalizeChrome()
	if !found {
		action = core.ResetChrome()
	}
	ctx, cancel := context.WithTimeout(context.Background(), kernelCallTimeout)
	defer cancel()
	layout, _, err := a.kernel.ReduceChromeLayout(ctx, a.chrome.coreItems, saved, action)
	if err != nil {
		a.notifyError(a.text.Errors.Core(err.Error()))
		return
	}
	a.chrome.apply(layout)
}

// reduceChrome sends one layout action to the kernel, shows the result and saves it
// when it changed. A failure leaves the arrangement as it was and is reported.
func (a *App) reduceChrome(action core.ChromeAction) {
	ctx, cancel := context.WithTimeout(context.Background(), kernelCallTimeout)
	defer cancel()
	layout, changed, err := a.kernel.ReduceChromeLayout(ctx, a.chrome.coreItems, a.chrome.layout, action)
	if err != nil {
		a.notifyError(a.text.Errors.Core(err.Error()))
		return
	}
	a.chrome.apply(layout)
	if a.project != nil && !a.chrome.isOpen(catalogIndex[itemFind]) {
		a.cancelProjectSearch(a.project)
	}
	// The Problems list copies the diagnostics it submits to Core. Drop that copy
	// when the tool window closes; opening it again asks Core for a fresh answer.
	if !a.chrome.isOpen(catalogIndex[itemProblems]) {
		a.problems.reset()
	}
	if !changed {
		return
	}
	saved := a.chrome.withAbsent(layout)
	if err := a.store.Save(layoutFile, saved); err != nil {
		a.notifyError(a.text.Errors.SaveFailed(err.Error()))
		return
	}
	a.chrome.saved = saved
}
