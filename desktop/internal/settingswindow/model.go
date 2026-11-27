package settingswindow

import (
	"strings"
	"sync/atomic"

	"github.com/1lck/Lithe-IDEA/desktop/internal/fontprefs"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
)

// This file holds the logic of the settings window that needs no screen: which pages the
// sidebar lists for a search, what the breadcrumb says, and how the two current
// settings map onto the controls that edit them. It takes the catalog's words as an
// argument and touches no Viva type, so the tests run it without a window.

// pageID names one entry of the sidebar: a group that holds pages, a page inside a group
// or a page on its own. The values are the order the sidebar lists them in, a group
// directly followed by its pages, which appendVisible relies on.
type pageID uint8

const (
	// pageAppearance is the group "Appearance & Behavior"; the six pages after it belong to it.
	pageAppearance pageID = iota
	pageGeneral
	pageNetwork
	pageEditor
	pageFonts
	pageKeymap
	pageProcessTermination
	// pagePlugins is a page on the top level of the sidebar.
	pagePlugins
	// pageVersionControl is the group "Version Control", which also has a page of its own:
	// the directory of its pages. The Git page after it belongs to it.
	pageVersionControl
	pageGit
	// pageBuild is the group "Build, Execution, Deployment", which also has a page of its
	// own: the directory of its pages and what needs attention. The two pages after it
	// belong to it, and so does a row for each kind of page plugins contribute to it, build
	// systems and compilers, which opens that kind's pages as Toolchains and Debuggers list
	// theirs.
	pageBuild
	pageToolchains
	pageDebuggers
	// pageLanguages is "Languages & Frameworks", a top-level page with no static pages
	// under it: the pages plugins contribute to it make it a group, and its own page is the
	// directory of them.
	pageLanguages
	// pageTools is the group "Tools"; the five pages after it belong to it.
	pageTools
	pageTerminal
	pageSearch
	pageConsole
	pageTrustedLocations
	pageRemoteWorkspace
	// pageAI is the group "AI"; the two pages after it belong to it.
	pageAI
	pageAIGeneration
	pageIDEAPI
	// pageAbout is the last entry of the top level: the application itself, its version,
	// its updates and where its community is, rather than a setting of a tool.
	pageAbout
	// pageCount is how many entries there are. As a parent it means "none": the parent
	// of an entry on the top level.
	pageCount
	noPage = pageCount
)

// parents says which group each entry is in. Writing it as a table keeps the shape of the
// sidebar in one place; the test of the table checks the order appendVisible depends on.
var parents = [pageCount]pageID{
	pageAppearance:         noPage,
	pageGeneral:            pageAppearance,
	pageNetwork:            pageAppearance,
	pageEditor:             pageAppearance,
	pageFonts:              pageAppearance,
	pageKeymap:             pageAppearance,
	pageProcessTermination: pageAppearance,
	pagePlugins:            noPage,
	pageVersionControl:     noPage,
	pageGit:                pageVersionControl,
	pageBuild:              noPage,
	pageToolchains:         pageBuild,
	pageDebuggers:          pageBuild,
	pageLanguages:          noPage,
	pageTools:              noPage,
	pageTerminal:           pageTools,
	pageSearch:             pageTools,
	pageConsole:            pageTools,
	pageTrustedLocations:   pageTools,
	pageRemoteWorkspace:    pageTools,
	pageAI:                 noPage,
	pageAIGeneration:       pageAI,
	pageIDEAPI:             pageAI,
	pageAbout:              noPage,
}

// initialPage is the page a new window opens on: the one page the new client offers.
const initialPage = pageGeneral

// initialOpen is the groups that start expanded. The group of the initial page does, so
// the row that is selected is on the screen.
func initialOpen() [pageCount]bool {
	var open [pageCount]bool
	open[pageAppearance] = true
	return open
}

// isGroup says whether any entry is inside id.
func isGroup(id pageID) bool {
	for child := pageID(0); child < pageCount; child++ {
		if parents[child] == id {
			return true
		}
	}
	return false
}

// ownsPage says whether the group id also opens a page of its own when its row is
// chosen, instead of only expanding and collapsing: Version Control, Build, Execution,
// Deployment and Languages & Frameworks open the directory of their pages
// (version_control_view.go, build_directory_view.go, languages_view.go), which the
// breadcrumb above one of those pages links to as well.
func ownsPage(id pageID) bool {
	return id == pageVersionControl || id == pageBuild || id == pageLanguages
}

// titleOf is the name of an entry in the language of messages.
func titleOf(messages *i18n.SettingsMessages, id pageID) string {
	switch id {
	case pageAppearance:
		return messages.AppearanceBehavior
	case pageGeneral:
		return messages.General
	case pageNetwork:
		return messages.Network
	case pageEditor:
		return messages.Editor
	case pageFonts:
		return messages.Fonts
	case pageKeymap:
		return messages.Keymap
	case pageProcessTermination:
		return messages.ProcessTermination
	case pagePlugins:
		return messages.Plugins
	case pageVersionControl:
		return messages.VersionControl
	case pageGit:
		return messages.Git
	case pageBuild:
		return messages.Build
	case pageToolchains:
		return messages.Toolchains
	case pageDebuggers:
		return messages.Debuggers
	case pageConsole:
		return messages.Console
	case pageTrustedLocations:
		return messages.TrustedLocations
	case pageRemoteWorkspace:
		return messages.RemoteWorkspace
	case pageLanguages:
		return messages.Languages
	case pageTools:
		return messages.Tools
	case pageTerminal:
		return messages.Terminal
	case pageSearch:
		return messages.SearchPage
	case pageAI:
		return messages.AI
	case pageAIGeneration:
		return messages.AIGeneration
	case pageIDEAPI:
		return messages.IDEAPI
	case pageAbout:
		return messages.About
	}
	return ""
}

// row is one line of the sidebar as it is shown.
type row struct {
	dynamic string
	title   string
	hit     int
	page    pageID
	// level is 0 on the top level and 1 for a page inside a group.
	level uint8
	// group says the row is a group, which has a chevron and expands instead of
	// opening a page; expanded says its pages are listed under it.
	group, expanded bool
	// kind is the kind of plugin pages under Build, Execution, Deployment the row opens, and
	// count how many pages of it there are.
	kind  string
	count int
	// overflow is how many tools the search matched on the row that lists every one of them.
	overflow int
	// path is where a search match lives, its ancestors' titles joined by " › ",
	// shown after its title. A string keeps a row comparable.
	path string
	// special is what a row of the search's sections stands for other than a page: a
	// section's title, a tool of the Toolchains page, a debugger, or the row that lists
	// every matching tool. ref is the tool's or the debugger's ID, status the tool's state.
	special     rowKind
	ref, status string
}

// rowKind is what a sidebar row stands for besides a page.
type rowKind uint8

const (
	rowPage rowKind = iota
	rowSection
	rowTool
	rowAdapter
	rowAllTools
)

// The search's sections: the settings pages, the tools of the Toolchains page and the
// debuggers, in that order.
const (
	sectionPages = iota
	sectionTools
	sectionDebuggers
)

// The keys of the rows that are not a page of the table nor a plugin's page. They are past
// any count of plugin pages and stay inside the list's non-negative 31-bit keys.
const (
	// kindHit is the row of a kind of plugin pages, by the kind's place in buildKinds.
	kindHit = 1 << 28
	// sectionHit is a section's title; allToolsHit the row listing every matching tool.
	sectionHit  = kindHit + 64
	allToolsHit = sectionHit + 16
	// toolHit and adapterHit are the rows of a tool and a debugger, by their place.
	toolHit    = 1 << 29
	adapterHit = toolHit + 1<<20
)

// foldQuery turns what the user typed into what titles are compared with: without the
// spaces around it and in lower case, so a search ignores case. An empty result lists
// every page.
func foldQuery(text string) string {
	return strings.ToLower(strings.TrimSpace(text))
}

// matches says whether the title of id contains the folded query.
func matches(messages *i18n.SettingsMessages, id pageID, query string) bool {
	return strings.Contains(strings.ToLower(titleOf(messages, id)), query)
}

// appendVisible appends the rows the sidebar lists to dst and returns it.
//
// Without a query it lists the top level, and the pages of the groups that open says are
// expanded. With a query it lists only what matches, and every group that has a match
// is expanded whatever the user left it as, because a match inside a collapsed group
// would otherwise be hidden from the search that looked for it. A group whose own title
// matches keeps all its pages, since the user named the whole group; otherwise only the
// pages that match are kept under it. A group with nothing to show is dropped.
func appendVisible(dst []row, messages *i18n.SettingsMessages, open *[pageCount]bool, query string) []row {
	searching := query != ""
	for id := pageID(0); id < pageCount; id++ {
		if parents[id] != noPage {
			// A page inside a group is listed with its group.
			continue
		}
		own := !searching || matches(messages, id, query)
		if !isGroup(id) {
			if own {
				dst = append(dst, row{page: id})
			}
			continue
		}
		expanded := searching || open[id]
		start := len(dst)
		dst = append(dst, row{page: id, group: true, expanded: expanded})
		if expanded {
			for child := id + 1; child < pageCount && parents[child] == id; child++ {
				if own || matches(messages, child, query) {
					dst = append(dst, row{page: child, level: 1})
				}
			}
		}
		if searching && !own && len(dst) == start+1 {
			dst = dst[:start]
		}
	}
	return dst
}

// crumb is one title of the breadcrumb and the page choosing it opens. link is set on a title
// before the last that has a page of its own to open.
type crumb struct {
	title string
	page  pageID
	link  bool
}

// appendBreadcrumb appends the titles that lead to id to dst and returns it: the group and
// then the page for a page inside a group, and the title alone for any other entry. The group
// links to its page when it has one.
func appendBreadcrumb(dst []crumb, messages *i18n.SettingsMessages, id pageID) []crumb {
	if parent := parents[id]; parent != noPage {
		dst = append(dst, crumb{title: titleOf(messages, parent), page: parent, link: ownsPage(parent)})
	}
	return append(dst, crumb{title: titleOf(messages, id), page: id})
}

// contributedParent is the entry a plugin's settings page of kind is listed under: build
// systems and compilers under Build, Execution, Deployment, and every other kind under
// Languages & Frameworks.
func contributedParent(kind string) pageID {
	if kind == "buildSystem" || kind == "compiler" {
		return pageBuild
	}
	return pageLanguages
}

// buildKinds are the kinds of plugin pages under Build, Execution, Deployment, in the
// order the sidebar and the Build page list them. Each kind has one row in the sidebar,
// whatever the count of its pages, and its page lists them (build_kind_view.go).
var buildKinds = [...]string{"buildSystem", "compiler"}

// kindIndex is the place of kind in buildKinds, or -1 for another kind.
func kindIndex(kind string) int {
	for index, k := range buildKinds {
		if k == kind {
			return index
		}
	}
	return -1
}

// kindTitle names a kind of plugin pages: its row's title and its page's.
func kindTitle(language i18n.Language, kind string) string {
	if kind == "compiler" {
		return i18n.Shared(language, "desktop.buildSettings.kindCompiler")
	}
	return i18n.Shared(language, "desktop.buildSettings.kindBuildSystem")
}

// pageKeywords are the words besides its title a search finds a page by.
func pageKeywords(language i18n.Language, id pageID) string {
	switch id {
	case pageGeneral:
		return i18n.Shared(language, "desktop.cli.title")
	case pageEditor:
		return i18n.Shared(language, "desktop.editorPrefs.autoCompletion") + " " +
			i18n.Shared(language, "desktop.editorPrefs.rainbowBrackets") + " " +
			i18n.Shared(language, "desktop.editorPrefs.rainbowVariables") + " " +
			i18n.Shared(language, "desktop.editorPrefs.indentGuides") + " " +
			i18n.Shared(language, "desktop.editorPrefs.rainbowIndentGuides")
	case pageBuild:
		return i18n.Shared(language, "desktop.buildSettings.keywordsBuild")
	case pageToolchains:
		return i18n.Shared(language, "desktop.buildSettings.keywordsToolchains")
	case pageDebuggers:
		return i18n.Shared(language, "desktop.buildSettings.keywordsDebuggers")
	case pageConsole:
		return i18n.Shared(language, "desktop.consoleSettings.keywords")
	case pageTrustedLocations:
		return i18n.Shared(language, "desktop.trustedLocations.keywords")
	case pageRemoteWorkspace:
		return i18n.Shared(language, "desktop.remoteSettings.keywords")
	}
	return ""
}

// toggleGroup expands a collapsed group and collapses an expanded one. It does nothing
// while a search is under way, because the search has expanded every group it lists and
// the row would otherwise appear to ignore the click, nor for an entry that is not a
// group. group says whether id is one now: an entry with pages of its own in the table
// above, or an entry plugins have put their settings pages under.
func toggleGroup(open *[pageCount]bool, id pageID, group, searching bool) {
	if searching || id >= pageCount || !group {
		return
	}
	open[id] = !open[id]
}

// The values of Values.Theme besides the empty one, which follows the system.
const (
	themeLight = "light"
	themeDark  = "dark"
)

// themeValues are the segments of the appearance choice in the order they are shown, as
// the values they store.
var themeValues = [...]string{"", themeLight, themeDark}

// themeIndex is the segment of the appearance choice for a stored theme. A value the
// choice does not know falls on the first segment, which follows the system, as the
// workbench does for it.
func themeIndex(theme string) int {
	for index, value := range themeValues {
		if value == theme {
			return index
		}
	}
	return 0
}

// themeValue is the theme to store for a segment of the appearance choice, the reverse of
// themeIndex. A segment out of range stores the empty theme.
func themeValue(index int) string {
	if index < 0 || index >= len(themeValues) {
		return ""
	}
	return themeValues[index]
}

// languageIndex is the option of the language list for a stored code. Option 0 follows
// the system, which is what an empty or unknown code does; the languages follow in the
// order i18n lists them.
func languageIndex(code string) int {
	language, ok := i18n.Parse(code)
	if !ok {
		return 0
	}
	for index, candidate := range i18n.Languages {
		if candidate == language {
			return index + 1
		}
	}
	return 0
}

// languageCode is the code to store for an option of the language list, the reverse of
// languageIndex. An option out of range stores the empty code, which follows the system.
func languageCode(index int) string {
	if index < 1 || index > len(i18n.Languages) {
		return ""
	}
	return i18n.Languages[index-1].Code()
}

// themeLabelsFor are the words of the appearance choice's segments, in the order of
// themeValues. The first segment follows the system and says what that is now, so the user
// sees which look "follow the system" gives before choosing it.
func themeLabelsFor(messages *i18n.SettingsMessages, systemDark bool) []string {
	effective := messages.Light
	if systemDark {
		effective = messages.Dark
	}
	return []string{messages.FollowSystem(effective), messages.Light, messages.Dark}
}

// languageLabelsFor are the options of the language list, in the order languageIndex counts
// them. The first follows the system and names the language it resolves to; each language
// that follows is written in its own name, so a user who cannot read the current language
// can still find theirs.
func languageLabelsFor(messages *i18n.SettingsMessages, system i18n.Language) []string {
	labels := make([]string, 0, len(i18n.Languages)+1)
	labels = append(labels, messages.FollowSystem(system.Native()))
	for _, language := range i18n.Languages {
		labels = append(labels, language.Native())
	}
	return labels
}

// windowDark says whether the window is painted dark for the current theme: a theme the
// user picked decides, and anything else follows the system's look.
func windowDark(theme string, system bool) bool {
	switch theme {
	case themeLight:
		return false
	case themeDark:
		return true
	}
	return system
}

// sanitize returns v with a value the window cannot show put back to following the
// system. This only determines the initial displayed value; opening the window does not
// write the stored setting.
func sanitize(v Values) Values {
	if _, ok := i18n.Parse(v.Language); !ok {
		v.Language = ""
	}
	if v.Theme != themeLight && v.Theme != themeDark {
		v.Theme = ""
	}
	if v.EditorTabRows != TabRowsMultiple {
		v.EditorTabRows = ""
	}
	if v.EditorTabOverflow != TabOverflowSqueeze {
		v.EditorTabOverflow = ""
	}
	v.Fonts = fontprefs.Normalize(v.Fonts)
	return v
}

// session is what one settings window remembers: the values shown by the controls, the page
// open, which groups of the sidebar are expanded, and whether the window has finished.
// Reopening a window that is still open keeps all of it, so the user finds the page and
// its current values where they left them.
//
// Everything but finished is touched only on the window's thread. finished is atomic
// because Controller.Open reads it from the thread of whichever window asked to open
// settings.
type session struct {
	values Values
	page   pageID
	open   [pageCount]bool
	// finished says OK or Cancel was chosen or the window is gone, so a second OK, a late
	// Enter or a reopen does not act on a window that is closing.
	finished atomic.Bool
}

// newSession returns the session of a window that opens on the page initialPage with the
// values starting from the settings in force.
func newSession(current Values) *session {
	return &session{values: sanitize(current), page: initialPage, open: initialOpen()}
}

// show opens page and expands the group it is in, so the row that is selected is on the
// screen. An entry that is a group or does not exist is left alone: a group has no page of
// its own.
func (s *session) show(page pageID) {
	if page >= pageCount || (isGroup(page) && !ownsPage(page)) {
		return
	}
	s.page = page
	if parent := parents[page]; parent != noPage {
		s.open[parent] = true
	}
}

// accept ends the session once, so a click and an Enter cannot close it twice.
func (s *session) accept() bool { return s.finished.CompareAndSwap(false, true) }

// cancel ends the session and reports whether it was still going. Previously selected
// values are already applied. The caller closes the window when it reports true.
func (s *session) cancel() bool { return s.finished.CompareAndSwap(false, true) }

// keyKind is the keys the window gives a meaning of its own, apart from the toolkit's key
// type so the decision below needs none of it.
type keyKind uint8

const (
	keyOther keyKind = iota
	keyEnter
	keyEscape
)

// keyAction is what the window does for a key.
type keyAction uint8

const (
	// actionNone leaves the key to the control that has the focus and the toolkit.
	actionNone keyAction = iota
	// actionAccept is OK and actionCancel is Cancel.
	actionAccept
	actionCancel
	// actionClearSearch empties the search field and keeps the window open.
	actionClearSearch
	// actionEndRecording stops recording a shortcut on the Keymap page and keeps the window
	// open.
	actionEndRecording
)

// keyContext is what decides what Enter and Escape mean at the moment.
type keyContext struct {
	// selectOpen says a drop-down list is open. It takes Enter to pick the option in
	// focus and Escape to close itself, so neither may also close the window.
	selectOpen bool
	// searching says the search field has the focus and queryEmpty that it holds no text.
	searching, queryEmpty bool
	// ownsEnter says the focused control acts on Enter itself: a button presses, a group
	// row expands and a choice picks. Enter must do that and not also press OK.
	ownsEnter bool
	// recording says the Keymap page is recording a shortcut. Enter is a key it may record,
	// and Escape stops the recording before it could close the window.
	recording bool
}

// decideKey says what the window does for key in ctx. Enter is OK and Escape is Cancel,
// as in the dialogs of an IDE; the exceptions are the cases where another control needs
// the key. In the search field Enter belongs to the field, and Escape first empties the
// field and only closes the window when there is nothing left to empty. While a shortcut
// is being recorded, Escape stops the recording and Enter is the recording's.
func decideKey(key keyKind, ctx keyContext) keyAction {
	if ctx.selectOpen {
		return actionNone
	}
	switch key {
	case keyEnter:
		if ctx.searching || ctx.ownsEnter || ctx.recording {
			return actionNone
		}
		return actionAccept
	case keyEscape:
		if ctx.recording {
			return actionEndRecording
		}
		if ctx.searching && !ctx.queryEmpty {
			return actionClearSearch
		}
		return actionCancel
	}
	return actionNone
}

func (r row) hitIndex() int {
	if r.dynamic != "" || r.kind != "" || r.special != rowPage {
		return r.hit
	}
	return int(r.page)
}
