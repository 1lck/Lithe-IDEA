package settingswindow

import (
	"math"
	"sync"
	"sync/atomic"

	"github.com/1lck/Lithe-IDEA/desktop/internal/appicon"
	"github.com/1lck/Lithe-IDEA/desktop/internal/fontprefs"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/uistyle"
	"github.com/1lck/Lithe-IDEA/desktop/internal/windowcontrols"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// The metrics of the window, after the macOS client's settings window and the log window.
const (
	// windowWidth and windowHeight are the size the window opens at until the user gives it
	// another, which it then keeps (Values.WindowWidth, Options.WindowResized).
	windowWidth, windowHeight = 1270, 700
	windowMinWidth            = 900
	windowMinHeight           = 668

	// titleHeight is the height of the title bar, which the system's window buttons sit in.
	titleHeight = 32
	// sidebarWidth is the width of the column of pages.
	sidebarWidth = 234
	// searchHeight is the height of the search field.
	searchHeight = 28

	// rowHeight is the height of a row of the sidebar.
	rowHeight = 24
	// chevronSlot is the room a group's chevron takes in front of a row, which is the column
	// Viva's Tree gives its own chevrons; the rows that are not groups keep it empty so every
	// tile lines up.
	chevronSlot  = 24
	chevronGlyph = 12
	// tileSize is the rounded square in front of a top-level row, tileGlyph the white glyph
	// in it, and tileGap the space between the tile and the title.
	tileSize   = 20
	tileRadius = 4
	tileGlyph  = 12
	tileGap    = 8
	// childIndent is where the title of a row inside a group starts, under the title of the
	// group. levelIndent is the Tree's step of a level, which a row's content pads up to where
	// its title starts.
	childIndent = chevronSlot + tileSize + tileGap
	levelIndent = childIndent / 2
	// sectionHeight is the height of a section's title in the search, the prototype's .hd.
	sectionHeight = 26
	// crumbHeight is the height of the breadcrumb, the prototype's .crumb.
	crumbHeight = 42

	// contentPad is the margin of the page at its sides.
	contentPad = 26
	// The cards of a page.
	cardRadius = 10
	cardPad    = 14
	cardGap    = 12
	// selectWidth is the width of the language list.
	selectWidth = 190
	// radioHeight is the height of one option of a radio group, radioSize the circle in
	// front of its words and radioDot the dot that fills the circle of the chosen one.
	radioHeight = 24
	radioSize   = 14
	radioDot    = 6
	// emptyWidth is the width the sentence of a page that is not available yet wraps at.
	emptyWidth = 360
	// footerHeight is the height of the bar with the buttons under its 1px top line, 50 in all
	// as in the prototype.
	footerHeight = 49
	// footerPad is the margin of the bar's buttons at its sides.
	footerPad = 16
)

// window is one open settings window and the model of its Page. Everything in it runs on
// its window thread, but for the fields that say so.
type window struct {
	cli                      cliRegistration
	associations             associationRegistration
	searchDraft              searchPreferencesDraft
	editorDelay              ui.Field
	editorDelayReady         bool
	editorPrefsError         string
	editorPreferencesChanged atomic.Pointer[editorPreferencesUpdate]
	rainbowLight             rainbowPaletteEditor
	rainbowDark              rainbowPaletteEditor
	scheme                   schemeDraft
	ctrl                     *Controller
	sess                     *session

	// win, stopWatch and gone are guarded by ctrl.mu: Controller.Open fills them in from the
	// thread that opened the window, and the window's own thread reads and clears them.
	win       *app.Window
	stopWatch func()
	gone      bool
	// openedSize is the size the window opened at and size the size of its content in the last
	// frame the system reported, which is kept when it differs (closed, Controller.ResizedWindow).
	// size is guarded by ctrl.mu too: the window's thread sets it, and the owner may read it
	// from its own thread.
	openedSize windowSize
	size       windowSize

	inv  app.Invalidator
	page *ui.Page

	market      *marketplaceState
	marketIcons marketplaceIcons
	install     *pluginInstallDialog
	// commands is the Installed tab's check of the commands plugins need and the dialog that
	// installs them (command_install.go).
	commands *commandInstalls
	// pluginTab is the open tab of the plugin page, one of the pluginTab constants:
	// what is installed, or the marketplace. installed is the Installed tab's own list,
	// filter and detail (installed_view.go).
	pluginTab int
	installed installedState
	// changelog is the releases the Installed tab's changelog has read (installed_changelog.go).
	changelog changelogState
	// pluginMenuOpen says the plugin page's gear menu is open, and repositoriesOpen the
	// window that manages the plugin repositories.
	pluginMenuOpen   bool
	repositoriesOpen bool
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
	// raised says Controller.open raised the window since its last paint; marketRecheck that
	// the plugin page, the next time it is painted, reads its plugins again when they are
	// stale, which entering the page or raising the window asks for. marketShown is whether
	// the last paint showed the plugin page.
	raised        atomic.Bool
	marketRecheck bool
	marketShown   bool
	// toolchains is the Build settings page's draft and loaded snapshot.
	toolchains *toolchainState
	stepping   *steppingState
	// apply is the footer's write of the Build pages' drafts.
	apply buildApply
	// kinds is the list of each kind of plugin pages under Build, by the kind's place in
	// buildKinds: its filter, its rows and the page it last showed.
	kinds [len(buildKinds)]kindState
	// languages is the directory of the Languages & Frameworks page (languages_view.go).
	languages      ui.ListState
	pluginSettings *pluginSettingsForm
	pluginForms    map[string]*pluginSettingsForm
	// region is the plugin view of the settings region on screen (plugin_region_view.go).
	region            *regionView
	formLimitReported bool
	dynamic           settingsSurfaces
	dynamicPage       string
	// contributorID is the plugin whose form a contributed page shows.
	contributorID   string
	settingsChanged atomic.Bool
	settingsNotices chan string
	// terminal is the Terminal page's list of installed shells.
	terminal terminalShellState
	// fonts is the Fonts page's list of installed fixed-pitch families, and fontEdit the
	// places checked on it and the unsaved look being set up for them (fonts_view.go).
	fonts    fontListState
	fontEdit fontEditState
	// generation is the Generation page's state (ai_generation.go).
	generation *aiGeneration
	// scrollbackField is the Terminal page's history field; scrollbackEditing says the user
	// typed in it since the stored number was last shown.
	scrollbackField   ui.Field
	scrollbackEditing bool
	// stopTimeField is the Process Termination page's stop time field; stopTimeEditing says
	// the user typed in it since the stored time was last shown.
	stopTimeField   ui.Field
	stopTimeEditing bool
	// network is the Network page's unsaved edit.
	network networkDraft
	// updates is the update card's unsaved feed address and channel switch (updates_view.go).
	updates updatesDraft
	// localHistory is the General page's unsaved local history settings and the open
	// project's history size (local_history_view.go).
	localHistory localHistoryDraft
	// about is the About page's copy result, and aboutFacts the build facts it shows, read
	// on its first paint (about_view.go).
	about      aboutState
	aboutFacts *aboutFacts
	// keymap is the Keymap page's filter and recording.
	keymap    keymapState
	keyImport keymapImportState

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
	themePick, languagePick, tabRowsPick, tabOverflowPick, shellPick, projectOpenPick, backgroundStrengthPick string
	marketSourcePick                                                                                          int
	// marketSourceDraft is the index URL being typed; marketSourceNotice the last refusal.
	marketSourceDraft  string
	marketSourceNotice string

	// What the current paint works from.
	text *i18n.Messages
	dark bool
	pal  palette
	// bp is the look of the Build, Execution, Deployment pages (build_style.go).
	bp    buildPalette
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
	rowsFor   sidebarKey
	rowsValid bool
	nav       ui.TreeState
	crumbs    []crumb

	// The words of the two lists, built for labelsFor.
	themeLabels    []string
	languageLabels []string
	languageCodes  []string
	labelsFor      labelsKey
	labelsValid    bool
}

// rowsKey is everything Core's projection of the sidebar is computed from.
type rowsKey struct {
	text  *i18n.Messages
	query string
	open  [pageCount]bool
}

// sidebarKey is everything the sidebar's rows are computed from: Core's projection, and while
// searching the tools and the debuggers that match.
type sidebarKey struct {
	rows     rowsKey
	revision uint64
	tools    toolchainWant
	adapters int
}

// labelsKey is everything the words of the two lists are computed from.
type labelsKey struct {
	text       *i18n.Messages
	systemDark bool
}

// windowSize is the size of a window's content area, in logical pixels.
type windowSize struct {
	width, height int
}

// openingSize is the size a window opens at: the one the user last gave it, or the default
// when none is kept, and never under the smallest.
func openingSize(width, height int) windowSize {
	if width <= 0 || height <= 0 {
		width, height = windowWidth, windowHeight
	}
	return windowSize{width: max(width, windowMinWidth), height: max(height, windowMinHeight)}
}

// newWindow returns a window whose values start from the settings in force.
func newWindow(c *Controller, current Values) *window {
	w := &window{ctrl: c, sess: newSession(current)}
	w.openedSize = openingSize(current.WindowWidth, current.WindowHeight)
	w.size = w.openedSize
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
	w.market.customFetch = c.opts.FetchMarketplaceSource
	w.market.setCustom(c.opts.MarketplaceSources)
	w.market.reportDiscarded = c.opts.MarketplaceError
	w.market.search.rank = c.opts.MarketplaceRank
	if current.MarketplaceQuery != nil {
		w.marketQuery = *current.MarketplaceQuery
		w.pluginTab = pluginTabMarketplace
	}
	w.market.search.report = c.opts.MarketplaceError
	w.marketIcons = newMarketplaceIcons(c.opts.MarketplaceIcon, c.opts.MarketplaceIconError)
	w.pluginSettings = newPluginSettingsForm(c.opts.PluginSettings)
	w.pluginForms = make(map[string]*pluginSettingsForm)
	w.settingsNotices = make(chan string, 64)
	w.dynamic = newSettingsSurfaces(c.opts)
	w.dynamic.bind()
	w.pluginSettings.report = func(err error) { reportSettingsError(c.opts, pluginSettingsOperation, err) }
	w.toolchains = newToolchainState(c.opts.Toolchains)
	w.toolchains.invalidate = func() { w.inv.Invalidate() }
	w.commands = newCommandInstalls(c.opts.CommandInstalls, func(operation string, err error) { reportSettingsError(c.opts, operation, err) }, func() { w.inv.Invalidate() })
	w.stepping = newSteppingState(c.opts.SteppingAdapters, c.opts.NormalizeSteppingFilters)
	w.terminal = newTerminalShellState(c.opts.TerminalShells)
	w.fonts = newFontListState(c.opts.MonospaceFamilies)
	w.changelog = newChangelogState(c.opts.PluginReleases, func(err error) { reportSettingsError(c.opts, "plugin_releases", err) })
	w.generation = newAIGeneration(c.opts, func() { w.inv.Invalidate() })
	w.nav.Node, w.nav.Key, w.nav.RowHeight, w.nav.Indent = w.navNode, w.navKey, rowHeight, levelIndent
	return w
}

// config is the native window's configuration: the Page paints it and routes its input.
func (w *window) config() app.Config {
	w.page = ui.NewPage(ui.PageConfig{
		View: w.view, Theme: &w.theme, Background: &w.background, Invalidator: &w.inv, BarStyle: uistyle.Bars,
		// Paths, values and sidebar entries cut short with an ellipsis show their whole value
		// when the pointer rests on them.
		EllipsisTooltips: true,
	})
	config := ui.Configure(w.page, app.Config{
		Title:          w.ctrl.text().Settings.Title,
		Icon:           appicon.Window(),
		Width:          w.openedSize.width,
		Height:         w.openedSize.height,
		MinWidth:       windowMinWidth,
		MinHeight:      windowMinHeight,
		WindowMode:     app.WindowCustomTitlebar,
		TitlebarHeight: titleHeight,
		WindowControls: func() app.WindowControlsStyle { return windowcontrols.Style(w.pal.text, w.ctrl.text()) },
		Invalidator:    &w.inv,
		OnWake:         w.wake,
		OnFrameChange:  w.framed,
		OnClosed:       w.closed,
		OnActivate:     w.refreshAssociations,
		// Chords of printable keys reach the window as shortcuts, not as keys of the
		// control that has the focus; the one the Keymap page records arrives here.
		OnShortcut: w.recordShortcut,
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
	w.takeEditorPreferences()
	if q, ok := w.takeQuery(); ok {
		// A search the workbench asks for is a search of the marketplace.
		w.marketQuery = q
		w.pluginTab = pluginTabMarketplace
	}
	if w.pluginRegistryChanged.Swap(false) {
		w.dynamic.invalidate()
		w.commands.invalidate()
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
	if w.raised.Swap(false) {
		w.marketRecheck = true
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

// framed takes the size of the window's content from a frame the system reports. It is the
// window's own size: Viva reports no frame while the window is full screen, maximized or
// minimized. A live resize reports every step, so the size is only noted here and kept when
// the window closes, never written per frame.
func (w *window) framed(frame gfx.Rect) {
	size := windowSize{width: int(math.Round(float64(frame.Width))), height: int(math.Round(float64(frame.Height)))}
	if size.width <= 0 || size.height <= 0 {
		return
	}
	w.ctrl.mu.Lock()
	w.size = size
	w.ctrl.mu.Unlock()
}

// resized is the size the user gave the window since it opened, if any. The caller holds
// ctrl.mu.
func (w *window) resized() (windowSize, bool) {
	return w.size, w.size != w.openedSize
}

// closed runs once the native window is gone, however it was closed: the session is over,
// the system look is no longer watched, the controller forgets the window, so the next Open
// makes a new one, and a size the user gave the window is kept for that one. The Page has
// cancelled its effects by then.
func (w *window) closed() {
	w.marketIcons.reset(0)
	w.closeRegion()
	w.dismissPluginInstall()
	if w.ctrl.opts.PluginInstallsClosed != nil {
		w.ctrl.opts.PluginInstallsClosed()
	}
	w.sess.finished.Store(true)
	c := w.ctrl
	c.mu.Lock()
	w.gone = true
	stop := w.stopWatch
	w.stopWatch = nil
	if c.current == w {
		c.current = nil
	}
	size, resized := w.resized()
	c.mu.Unlock()
	if stop != nil {
		stop()
	}
	if resized && c.opts.WindowResized != nil {
		c.opts.WindowResized(size.width, size.height)
	}
}

// accept is OK: it writes the Build pages' drafts, then closes the window (build_apply.go).
// A second OK, such as an Enter that arrives with a click, joins the write that is out.
func (w *window) accept() {
	w.startApply(true)
}

// cancel is Cancel: it drops the Build pages' drafts and closes the window without undoing
// already applied settings. It waits for nothing: while a write is out, Cancel is off.
func (w *window) cancel() {
	if w.apply.active() {
		return
	}
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
	w.bp = buildPaletteFor(w.dark)
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
	w.marketIcons.take()
	toolchainFailed := w.toolchains.take()
	saved, err, done := w.stepping.take()
	if done && err == nil {
		w.setSteppingFilters(saved.adapter, &saved.filters)
	}
	w.advanceApply(toolchainFailed, steppingResult{done: done, err: err})
	w.terminal.take()
	w.fonts.take()
	w.changelog.take()
	w.takeKeymapImport()
	w.takeSearchPreferences()
	w.commands.take()
	if w.dynamic.take() {
		w.rowsValid = false
	}
	ended, kept := w.market.take()
	w.reportMarket(ended, kept)
	w.market.search.take(w.market, w.marketQuery)
	w.pluginSettings.take()
	for _, form := range w.pluginForms {
		if form != w.pluginSettings {
			form.take()
		}
	}
}

// reportMarket tells the owner how the fetch that just ended went: that it failed, or how
// many entries of the index were rejected. kept is the failure of a background refresh, which
// leaves the plugins it refreshed shown; the owner logs it like any other failure.
func (w *window) reportMarket(ended bool, kept error) {
	if !ended {
		return
	}
	switch {
	case kept != nil && w.ctrl.opts.MarketplaceError != nil:
		w.ctrl.opts.MarketplaceError(kept)
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
	w.declareCLI(c)
	w.declareAssociations(c)
	if d := &w.searchDraft; d.effect != nil && d.work != nil {
		ui.Effect(c, d.effect, d.work)
	}
	w.toolchains.declare(c)
	w.stepping.declare(c)
	w.terminal.declare(c)
	w.fonts.declare(c)
	w.changelog.declare(c)
	if s := &w.keyImport; s.open && s.effect != nil && s.request != nil {
		ui.Effect(c, s.effect, s.request)
	}
	w.commands.declare(c)
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
	projected := w.ctrl.opts.SettingsNavigation != nil
	if projected {
		w.dynamic.request(key)
	}
	full := sidebarKey{rows: key, revision: w.dynamic.revision}
	if w.query != "" {
		full.tools, full.adapters = w.searchSources()
	}
	if w.rowsValid && full == w.rowsFor {
		return
	}
	var pages []row
	if projected {
		pages = w.dynamic.rows
	} else {
		pages = appendVisible(nil, &w.text.Settings, &key.open, w.query)
	}
	if w.query == "" {
		w.rows = pages
	} else {
		w.rows = w.searchSections(pages)
	}
	w.rowsFor, w.rowsValid = full, true
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

// setHideChangeLists and setHideParentReferences store a change of a Commit switch and hand it
// to the settings owner at once, like setHideGitGutter.
func (w *window) setHideChangeLists(value bool, force bool) {
	if w.sess.finished.Load() || (!force && w.sess.values.HideChangeLists == value) {
		return
	}
	w.sess.values.HideChangeLists = value
	if w.ctrl.opts.SetHideChangeLists != nil {
		w.ctrl.opts.SetHideChangeLists(value)
	}
}

func (w *window) setHideParentReferences(value bool, force bool) {
	if w.sess.finished.Load() || (!force && w.sess.values.HideParentReferences == value) {
		return
	}
	w.sess.values.HideParentReferences = value
	if w.ctrl.opts.SetHideParentReferences != nil {
		w.ctrl.opts.SetHideParentReferences(value)
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

// setConsoleEncoding stores a decoding preference for newly started consoles.
func (w *window) setConsoleEncoding(value string, force bool) {
	if w.sess.finished.Load() || (!force && w.sess.values.ConsoleEncoding == value) {
		return
	}
	w.sess.values.ConsoleEncoding = value
	if w.ctrl.opts.SetConsoleEncoding != nil {
		w.ctrl.opts.SetConsoleEncoding(value)
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
	seconds := func(v *uint32) int64 {
		if v == nil {
			return -1
		}
		return int64(*v)
	}
	return a.RunServicesOnExit == b.RunServicesOnExit && a.TerminalOnQuit == b.TerminalOnQuit &&
		confirms(a.ConfirmTerminalTabClose) == confirms(b.ConfirmTerminalTabClose) &&
		a.StartupSweep == b.StartupSweep && seconds(a.GracefulStopSeconds) == seconds(b.GracefulStopSeconds)
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
