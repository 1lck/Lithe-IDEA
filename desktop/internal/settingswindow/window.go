package settingswindow

import (
	"sync"
	"sync/atomic"

	"github.com/1lck/Lithe-IDEA/desktop/internal/appicon"
	"github.com/1lck/Lithe-IDEA/desktop/internal/fontprefs"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/windowcontrols"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// The metrics of the window, after the macOS client's settings window and the log window.
const (
	windowWidth, windowHeight = 1040, 720
	windowMinWidth            = 760
	windowMinHeight           = 520

	// titleHeight is the height of the title bar, which the system's window buttons sit in.
	titleHeight = 28
	// sidebarWidth is the width of the column of pages.
	sidebarWidth = 236
	// searchHeight is the height of the search field.
	searchHeight = 28

	// rowHeight is the height of a row of the sidebar.
	rowHeight = 28
	// chevronSlot is the room a group's chevron takes in front of a row, which the rows that
	// are not groups keep empty so every tile lines up.
	chevronSlot  = 24
	chevronGlyph = 12
	// tileSize is the rounded square in front of a top-level row, tileGlyph the white glyph
	// in it.
	tileSize   = 18
	tileRadius = 4
	tileGlyph  = 12
	// childIndent is what a row inside a group is indented by, so its title lines up with
	// the title of the group.
	childIndent = chevronSlot + tileSize + 8

	// contentPad is the margin of the page at its sides.
	contentPad = 24
	// The cards of a page.
	cardRadius = 8
	cardPad    = 14
	cardGap    = 12
	// selectWidth is the width of the language list.
	selectWidth = 190
	// radioHeight is the height of one option of a radio group, radioSize the circle in
	// front of its words and radioDot the dot that fills the circle of the chosen one.
	// radioIndent is how far an option that refines another is set in, so its circle sits
	// under the words of the option it refines.
	radioHeight = 24
	radioSize   = 14
	radioDot    = 6
	radioIndent = radioSize + 8
	// emptyWidth is the width the sentence of a page that is not available yet wraps at.
	emptyWidth = 360
	// footerHeight is the height of the bar with the buttons.
	footerHeight = 52
	// footerPad is the margin of the bar's buttons at its sides.
	footerPad = 16
)

// window is one open settings window and the model of its Page. Everything in it runs on
// its window thread, but for the fields that say so.
type window struct {
	ctrl *Controller
	sess *session

	// win, stopWatch and gone are guarded by ctrl.mu: Controller.Open fills them in from the
	// thread that opened the window, and the window's own thread reads and clears them.
	win       *app.Window
	stopWatch func()
	gone      bool

	inv  app.Invalidator
	page *ui.Page

	market *marketplaceState
	// marketSplit is the plugin list's divider. marketPreferred is the width the user chose,
	// which a narrow window clamps only for as long as it is narrow, marketApplied the width
	// the last paint gave the divider (a different Pos means the user moved it since) and
	// marketMoved that a move is waiting for its release to be saved.
	marketSplit     ui.SplitterState
	marketPreferred float32
	marketApplied   float32
	marketMoved     bool
	// requestedPage is the page Controller.open asked an already open window to switch to,
	// as the pageID plus one so that zero means no request. It is atomic because the
	// controller sets it from the thread of whichever window asked; wake takes it on the
	// window's own thread.
	requestedPage         atomic.Uint32
	pluginRegistryChanged atomic.Bool
	// toolchains is the Build settings page's draft and loaded snapshot.
	toolchains        *toolchainState
	stepping          *steppingState
	pluginSettings    *pluginSettingsForm
	pluginForms       map[string]*pluginSettingsForm
	formLimitReported bool
	dynamic           settingsSurfaces
	dynamicPage       string
	// contributorID is the plugin whose form a contributed page shows.
	contributorID   string
	settingsChanged atomic.Bool
	settingsNotices chan string
	// terminal is the Terminal page's list of installed shells.
	terminal terminalShellState
	// fonts is the Fonts page's list of installed fixed-pitch families.
	fonts fontListState
	// agent is the AI pages' state (agent_settings.go).
	agent *agentSettings
	// mcp is the MCP Configuration page's state.
	mcp *mcpState
	// scrollbackField is the Terminal page's history field; scrollbackEditing says the user
	// typed in it since the stored number was last shown.
	scrollbackField   ui.Field
	scrollbackEditing bool
	// keymap is the Keymap page's filter and recording.
	keymap keymapState

	// focusSearch asks the sidebar's search field, declared later in the paint, to take the
	// focus (the platform's Find).
	focusSearch bool
	// searchField is the sidebar's search and marketQuery the marketplace's text.
	searchField ui.Field
	marketQuery string
	// queryMu guards queryWanted, the query a request set for the next paint (requestQuery).
	queryMu     sync.Mutex
	queryWanted *string
	// The values the controls of the pages write into, set from the session's values in
	// each paint: a change the control makes is what the window then applies.
	themePick, languagePick, tabRowsPick, tabOverflowPick, shellPick string
	marketSourcePick                                                 int

	// What the current paint works from.
	text  *i18n.Messages
	dark  bool
	pal   palette
	theme ui.Theme
	// background is what the page fills the window with, which follows the look.
	background ui.Color
	// themed says theme has been built and themedDark which look it was built for, so it
	// is built again only when the look changes.
	themed     bool
	themedDark bool
	query      string
	// extent is the width of the window beside the sidebar, the room the pages have.
	extent float32

	// rows is the sidebar as listed for rowsFor, rebuilt only when what it depends on has
	// changed. nav is the Tree that shows them.
	rows      []row
	rowsFor   rowsKey
	rowsValid bool
	nav       ui.TreeState
	crumbs    []string

	// The words of the two lists, built for labelsFor.
	themeLabels    []string
	languageLabels []string
	languageCodes  []string
	labelsFor      labelsKey
	labelsValid    bool
}

// rowsKey is everything the sidebar's rows are computed from.
type rowsKey struct {
	text  *i18n.Messages
	query string
	open  [pageCount]bool
}

// labelsKey is everything the words of the two lists are computed from.
type labelsKey struct {
	text       *i18n.Messages
	systemDark bool
}

// newWindow returns a window whose values start from the settings in force.
func newWindow(c *Controller, current Values) *window {
	w := &window{ctrl: c, sess: newSession(current)}
	width := current.MarketplaceWidth
	if width <= 0 {
		width = marketListWidth
	}
	w.marketPreferred = min(max(width, marketMinWidth), marketMaxWidth)
	w.marketSplit = ui.SplitterState{Pos: w.marketPreferred}
	w.marketApplied = w.marketPreferred
	w.market = newMarketplaceState(c.opts.Marketplace)
	w.market.official = c.opts.MarketplaceOfficial
	w.market.installed = c.opts.MarketplaceInstalled
	w.market.reportDiscarded = c.opts.MarketplaceError
	w.market.search.rank = c.opts.MarketplaceRank
	w.marketQuery = current.MarketplaceQuery
	w.market.search.report = c.opts.MarketplaceError
	w.pluginSettings = newPluginSettingsForm(c.opts.PluginSettings)
	w.pluginForms = make(map[string]*pluginSettingsForm)
	w.settingsNotices = make(chan string, 64)
	w.dynamic = newSettingsSurfaces(c.opts)
	w.dynamic.bind()
	w.pluginSettings.report = func(err error) { reportSettingsError(c.opts, err) }
	w.toolchains = newToolchainState(c.opts.Toolchains)
	w.stepping = newSteppingState(c.opts.SteppingAdapters, c.opts.NormalizeSteppingFilters)
	w.terminal = newTerminalShellState(c.opts.TerminalShells)
	w.fonts = newFontListState(c.opts.MonospaceFamilies)
	w.agent = newAgentSettings(c.opts, func() { w.inv.Invalidate() })
	w.mcp = newMCPState(c.opts.MCP)
	w.nav.Node, w.nav.Key, w.nav.RowHeight, w.nav.Indent = w.navNode, w.navKey, rowHeight, childIndent
	return w
}

// config is the native window's configuration: the Page paints it and routes its input.
func (w *window) config() app.Config {
	w.page = ui.NewPage(ui.PageConfig{View: w.view, Theme: &w.theme, Background: &w.background, Invalidator: &w.inv})
	config := w.page.Config(app.Config{
		Title:          w.ctrl.text().Settings.Title,
		Icon:           appicon.Window(),
		Width:          windowWidth,
		Height:         windowHeight,
		MinWidth:       windowMinWidth,
		MinHeight:      windowMinHeight,
		WindowMode:     app.WindowCustomTitlebar,
		TitlebarHeight: titleHeight,
		WindowControls: func() app.WindowControlsStyle { return windowcontrols.Style(w.pal.text, w.ctrl.text()) },
		Invalidator:    &w.inv,
		OnWake:         w.wake,
		OnClosed:       w.closed,
	})
	paint := config.Paint
	config.Paint = func(canvas *gfx.Canvas, size gfx.Size) {
		w.prepare(size)
		paint(canvas, size)
	}
	return config
}

// requestPage asks the window to show page. It is safe from any goroutine: the switch
// happens on the window's thread at the repaint it requests, where it also empties the
// search, because a search that does not list the page would leave no row selected.
func (w *window) requestPage(page pageID) {
	w.requestedPage.Store(uint32(page) + 1)
	w.inv.Invalidate()
}

// requestQuery asks the window to set the marketplace search text to query on its next paint; it
// is safe to call from any goroutine.
func (w *window) requestQuery(query string) {
	w.queryMu.Lock()
	w.queryWanted = &query
	w.queryMu.Unlock()
	w.inv.Invalidate()
}

// takeQuery returns the query a request set, once.
func (w *window) takeQuery() (string, bool) {
	w.queryMu.Lock()
	defer w.queryMu.Unlock()
	if w.queryWanted == nil {
		return "", false
	}
	q := *w.queryWanted
	w.queryWanted = nil
	return q, true
}

// wake runs on the window thread right before each repaint an Invalidate requested. It
// takes a page request and what the plugin registry and the settings sources changed.
func (w *window) wake() {
	if q, ok := w.takeQuery(); ok {
		w.marketQuery = q
	}
	if w.pluginRegistryChanged.Swap(false) {
		w.dynamic.invalidate()
		w.rowsValid = false
		w.settingsChanged.Store(true)
		if w.market.source == 2 {
			w.market.close()
			w.market.start()
		}
	}
	if w.settingsChanged.Swap(false) {
		for _, form := range w.pluginForms {
			form.sourceChanged()
		}
	}
	for count := len(w.settingsNotices); count > 0; count-- {
		id := <-w.settingsNotices
		if form := w.pluginForms[id]; form != nil {
			form.sourceChanged()
		}
	}
	if requested := w.requestedPage.Swap(0); requested != 0 {
		w.searchField.SetText("")
		w.selectSettingsPage(pageID(requested-1), "")
	}
}

// watchSystem makes the window repaint when the system switches between its light and dark
// looks, because a window following the system is painted in the system's look. A window
// that is already gone is not watched.
func (w *window) watchSystem() {
	stop := app.WatchSystemAppearance(w.inv.Invalidate)
	c := w.ctrl
	c.mu.Lock()
	gone := w.gone
	if !gone {
		w.stopWatch = stop
	}
	c.mu.Unlock()
	if gone && stop != nil {
		stop()
	}
}

// native is the native window, nil until Controller.Open has it.
func (w *window) native() *app.Window {
	w.ctrl.mu.Lock()
	defer w.ctrl.mu.Unlock()
	return w.win
}

// closed runs once the native window is gone, however it was closed: the session is over,
// the system look is no longer watched and the controller forgets the window, so the next
// Open makes a new one. The Page has cancelled its effects by then.
func (w *window) closed() {
	w.sess.finished.Store(true)
	c := w.ctrl
	c.mu.Lock()
	w.gone = true
	stop := w.stopWatch
	w.stopWatch = nil
	if c.current == w {
		c.current = nil
	}
	c.mu.Unlock()
	if stop != nil {
		stop()
	}
}

// accept is OK: it closes the window. A second OK, such as an Enter
// that arrives with a click, does nothing.
func (w *window) accept() {
	if w.sess.accept() {
		w.closeNative()
	}
}

// cancel is Cancel: it closes the window without undoing already applied settings.
func (w *window) cancel() {
	if w.sess.cancel() {
		w.closeNative()
	}
}

// closeNative closes the native window. Closing is safe from inside a paint, which is
// where OK and Cancel are chosen.
func (w *window) closeNative() {
	if win := w.native(); win != nil {
		win.Close()
	}
}

// prepare runs before each paint, outside the page's declaration: it takes what the
// background work finished, then settles the look, the words and the sidebar's rows the
// declaration reads.
func (w *window) prepare(size gfx.Size) {
	w.collect()
	w.extent = max(0, size.Width-sidebarWidth-1)
	w.text = w.ctrl.text()
	w.dark = windowDark(w.sess.values.Theme, w.ctrl.systemDark())
	w.pal = paletteFor(w.dark)
	if !w.themed || w.themedDark != w.dark {
		w.theme, w.themed, w.themedDark = windowTheme(w.dark, w.pal), true, w.dark
	}
	w.background = w.pal.window
	w.query = foldQuery(w.searchField.Text())
	w.refreshRows()
	w.refreshLabels()
}

// collect takes the result of each background request on the window thread.
func (w *window) collect() {
	w.toolchains.take()
	if saved, ok := w.stepping.take(); ok {
		w.setSteppingFilters(saved.adapter, &saved.filters)
	}
	w.terminal.take()
	w.fonts.take()
	w.mcp.take()
	if w.dynamic.take() {
		w.rowsValid = false
	}
	previous := w.market.status
	w.market.take()
	w.reportMarket(previous)
	w.market.search.take(w.market, w.marketQuery)
	w.pluginSettings.take()
	for _, form := range w.pluginForms {
		if form != w.pluginSettings {
			form.take()
		}
	}
}

// reportMarket tells the owner how the fetch that just ended went: that it failed, or how
// many entries of the index were rejected.
func (w *window) reportMarket(previous marketStatus) {
	if previous != marketLoading {
		return
	}
	switch {
	case w.market.status == marketFailed && w.ctrl.opts.MarketplaceError != nil:
		w.ctrl.opts.MarketplaceError(w.market.err)
	case w.market.status == marketReady && len(w.market.snapshot.Index.Rejected) > 0 && w.ctrl.opts.MarketplaceRejected != nil:
		w.ctrl.opts.MarketplaceRejected(len(w.market.snapshot.Index.Rejected))
	}
}

// declareWork declares every background request the window has asked for. It runs at the end
// of the declaration, so a request made while the page was declared starts in the same
// paint, and in every paint, so leaving a page does not cancel what it asked for.
func (w *window) declareWork(c ui.C) {
	w.toolchains.declare(c)
	w.stepping.declare(c)
	w.terminal.declare(c)
	w.fonts.declare(c)
	w.mcp.declare(c)
	w.dynamic.declare(c)
	w.market.declare(c)
	w.market.search.declare(c)
	w.pluginSettings.declare(c)
	for _, form := range w.pluginForms {
		if form != w.pluginSettings {
			form.declare(c)
		}
	}
}

// refreshRows rebuilds the sidebar's rows when the language, the search or the expanded
// groups have changed since they were built.
func (w *window) refreshRows() {
	key := rowsKey{text: w.text, query: w.query, open: w.sess.open}
	if w.rowsValid && key == w.rowsFor {
		return
	}
	if w.ctrl.opts.SettingsNavigation != nil {
		w.dynamic.request(key)
		w.rows = w.dynamic.rows
	} else {
		w.rows = appendVisible(w.rows[:0], &w.text.Settings, &key.open, w.query)
	}
	w.rowsFor, w.rowsValid = key, true
}

// refreshLabels rebuilds the words of the appearance choice and the language list when the
// language or the system's look has changed since they were built.
func (w *window) refreshLabels() {
	systemDark := w.ctrl.systemDark()
	key := labelsKey{text: w.text, systemDark: systemDark}
	if w.labelsValid && key == w.labelsFor {
		return
	}
	w.themeLabels = themeLabelsFor(&w.text.Settings, systemDark)
	w.languageLabels = languageLabelsFor(&w.text.Settings, w.ctrl.opts.SystemLanguage)
	if w.languageCodes == nil {
		w.languageCodes = append([]string{""}, make([]string, len(i18n.Languages))...)
		for index, language := range i18n.Languages {
			w.languageCodes[index+1] = language.Code()
		}
	}
	w.labelsFor, w.labelsValid = key, true
}

// setLanguage and setTheme notify only the field the user changed, avoiding overwriting
// another setting with an old window snapshot.
func (w *window) setLanguage(value string, force bool) {
	if w.sess.finished.Load() || (!force && w.sess.values.Language == value) {
		return
	}
	w.sess.values.Language = value
	if w.ctrl.opts.SetLanguage != nil {
		w.ctrl.opts.SetLanguage(value)
	}
}

func (w *window) setTheme(value string, force bool) {
	if w.sess.finished.Load() || (!force && w.sess.values.Theme == value) {
		return
	}
	w.sess.values.Theme = value
	if w.ctrl.opts.SetTheme != nil {
		w.ctrl.opts.SetTheme(value)
	}
}

// setTabRows and setTabOverflow notify the change of one of the two tab settings in the
// same way.
func (w *window) setTabRows(value string, force bool) {
	if w.sess.finished.Load() || (!force && w.sess.values.EditorTabRows == value) {
		return
	}
	w.sess.values.EditorTabRows = value
	if w.ctrl.opts.SetTabRows != nil {
		w.ctrl.opts.SetTabRows(value)
	}
}

func (w *window) setTabOverflow(value string, force bool) {
	if w.sess.finished.Load() || (!force && w.sess.values.EditorTabOverflow == value) {
		return
	}
	w.sess.values.EditorTabOverflow = value
	if w.ctrl.opts.SetTabOverflow != nil {
		w.ctrl.opts.SetTabOverflow(value)
	}
}

// setTerminalShell notifies the change of the default shell in the same way. An empty value
// is automatic.
func (w *window) setTerminalShell(value string, force bool) {
	if w.sess.finished.Load() || (!force && w.sess.values.TerminalShell == value) {
		return
	}
	w.sess.values.TerminalShell = value
	if w.ctrl.opts.SetTerminalShell != nil {
		w.ctrl.opts.SetTerminalShell(value)
	}
}

// setFonts stores a change of the font list and hands it to the settings owner at once, as
// setTabRows does. The list is normalized before it is kept, so the page and the owner always
// see every scope in exactly one font, and a list that means the same as the one in force is
// not sent again. The owner gets its own copy, so what it keeps cannot be changed through the
// window's list.
func (w *window) setFonts(fonts []fontprefs.Font, force bool) {
	if w.sess.finished.Load() || (!force && fontprefs.Equal(w.sess.values.Fonts, fonts)) {
		return
	}
	w.sess.values.Fonts = fontprefs.Normalize(fonts)
	if w.ctrl.opts.SetFonts != nil {
		w.ctrl.opts.SetFonts(fontprefs.Normalize(w.sess.values.Fonts))
	}
}

// setHideGitGutter and setInlineGitBlame store a change of a Version Control switch and hand it
// to the settings owner at once, as setTabRows does.
func (w *window) setHideGitGutter(value bool, force bool) {
	if w.sess.finished.Load() || (!force && w.sess.values.HideGitGutter == value) {
		return
	}
	w.sess.values.HideGitGutter = value
	if w.ctrl.opts.SetHideGitGutter != nil {
		w.ctrl.opts.SetHideGitGutter(value)
	}
}

func (w *window) setInlineGitBlame(value bool, force bool) {
	if w.sess.finished.Load() || (!force && w.sess.values.InlineGitBlame == value) {
		return
	}
	w.sess.values.InlineGitBlame = value
	if w.ctrl.opts.SetInlineGitBlame != nil {
		w.ctrl.opts.SetInlineGitBlame(value)
	}
}

// setProcessTermination stores a change of the Process Termination page and hands it to the
// settings owner at once.
func (w *window) setProcessTermination(value ProcessTermination, force bool) {
	if w.sess.finished.Load() || (!force && sameProcessTermination(w.sess.values.ProcessTermination, value)) {
		return
	}
	w.sess.values.ProcessTermination = value
	if w.ctrl.opts.SetProcessTermination != nil {
		w.ctrl.opts.SetProcessTermination(value)
	}
}

// sameProcessTermination compares two settings by what they store.
func sameProcessTermination(a, b ProcessTermination) bool {
	confirms := func(v *bool) int {
		if v == nil {
			return -1
		}
		if *v {
			return 1
		}
		return 0
	}
	return a.RunServicesOnExit == b.RunServicesOnExit && a.TerminalOnQuit == b.TerminalOnQuit &&
		confirms(a.ConfirmTerminalTabClose) == confirms(b.ConfirmTerminalTabClose)
}

// setDisableSemanticHighlight stores a change of the Editor page's semantic switch and hands
// it to the settings owner at once.
func (w *window) setDisableSemanticHighlight(value bool, force bool) {
	if w.sess.finished.Load() || (!force && w.sess.values.DisableSemanticHighlight == value) {
		return
	}
	w.sess.values.DisableSemanticHighlight = value
	if w.ctrl.opts.SetDisableSemanticHighlight != nil {
		w.ctrl.opts.SetDisableSemanticHighlight(value)
	}
}
