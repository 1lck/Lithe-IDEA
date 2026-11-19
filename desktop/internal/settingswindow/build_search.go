package settingswindow

import (
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
)

// The sidebar's search follows the prototype docs/design/build-execution-settings.html: the
// settings pages it matched, then the tools of the Toolchains page and the debuggers whose
// names it matched, each section under its title. Choosing a tool or a debugger opens its page
// on it and ends the search.

const (
	// searchToolLimit and searchAdapterLimit are how many tools and debuggers the prototype's
	// sections list; the tools past the limit are behind a row that opens the Toolchains page
	// filtered by the search.
	searchToolLimit    = 8
	searchAdapterLimit = 5
)

// searchSources asks for what the search's sections list besides the pages, and names what
// arrived: the tools' projection, and how many debuggers there are, -1 before they loaded.
func (w *window) searchSources() (toolchainWant, int) {
	var tools toolchainWant
	if t := w.toolchains; t.available() {
		t.ensureLoaded()
		t.requestSearch(w.query)
		if t.searchReady(w.query) {
			tools = t.search.got
		}
	}
	adapters := -1
	if s := w.stepping; s.available() {
		s.beginLoad()
		if s.loaded {
			adapters = len(s.adapters)
		}
	}
	return tools, adapters
}

// searchSections are the sidebar's rows of a search: each section that has a match under its
// title. pages are the matched settings pages, which the result does not share.
func (w *window) searchSections(pages []row) []row {
	language := w.marketLanguage()
	rows := make([]row, 0, len(pages)+searchToolLimit+searchAdapterLimit+4)
	section := func(index int, title string) {
		rows = append(rows, row{special: rowSection, hit: sectionHit + index, title: title})
	}
	if len(pages) > 0 {
		section(sectionPages, i18n.Shared(language, "desktop.buildSettings.searchPages"))
		rows = append(rows, pages...)
	}
	if t := w.toolchains; t.available() && t.searchReady(w.query) {
		scope := t.current()
		matched := 0
		for _, projected := range t.search.view.Rows {
			entry := t.search.entry(projected)
			if entry == nil {
				continue
			}
			if matched == 0 {
				section(sectionTools, i18n.Shared(language, "desktop.buildSettings.searchTools"))
			}
			if matched < searchToolLimit {
				tool := &entry.tool
				rows = append(rows, row{
					special: rowTool, hit: toolHit + matched, title: toolchainName(tool), ref: tool.ID,
					status: projected.Status, path: toolchainPluginName(scope, tool.PluginID, tool.PluginName),
				})
			}
			matched++
		}
		if matched > searchToolLimit {
			rows = append(rows, row{special: rowAllTools, hit: allToolsHit, overflow: matched})
		}
	}
	if s := w.stepping; s.available() && s.loaded {
		shown := 0
		for _, adapter := range s.adapters {
			if shown == searchAdapterLimit {
				break
			}
			if !strings.Contains(strings.ToLower(adapter.Name), w.query) && !strings.Contains(strings.ToLower(steppingPluginName(adapter)), w.query) {
				continue
			}
			if shown == 0 {
				section(sectionDebuggers, i18n.Shared(language, "desktop.buildSettings.searchDebuggers"))
			}
			rows = append(rows, row{special: rowAdapter, hit: adapterHit + shown, title: adapter.Name, ref: adapter.ID, path: i18n.Shared(language, "desktop.buildSettings.steppingTab")})
			shown++
		}
	}
	// Pages alone need no heading: the search reads as it did before tools and debuggers joined.
	if len(pages) > 0 && len(rows) == len(pages)+1 {
		return rows[1:]
	}
	return rows
}

// chooseSearchRow opens what a row of the search's sections stands for and ends the search.
// It reports whether the row was one; a page's row opens as it does outside a search.
func (w *window) chooseSearchRow(r row) bool {
	switch r.special {
	case rowSection:
		return true
	case rowTool:
		t := w.toolchains
		t.reveal(r.ref, t.searchGroup(r.ref))
		w.openBuildChild(pageToolchains)
	case rowAllTools:
		w.toolchains.showMatches(w.query)
		w.openBuildChild(pageToolchains)
	case rowAdapter:
		w.stepping.selected, w.stepping.query, w.stepping.add = r.ref, "", ""
		w.openBuildChild(pageDebuggers)
	default:
		return false
	}
	w.clearSearch()
	return true
}

// openBuildChild shows a page under Build, Execution, Deployment with Build expanded, so its
// row is on the screen once the search ends.
func (w *window) openBuildChild(page pageID) {
	w.sess.open[pageBuild] = true
	w.selectSettingsPage(page, "")
}
