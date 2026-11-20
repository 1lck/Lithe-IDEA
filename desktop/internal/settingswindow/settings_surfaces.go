package settingswindow

import (
	"context"
	"errors"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/ui"
)

type surfacesResult struct {
	pageIndices map[string]int
	labels      map[string][]string
	ids         map[string][]string
	pages       []core.SettingsPage
	rows        []row
	err         error
}

// surfacesKey names one request of the catalog: the sidebar it is for and how many times
// the catalog was invalidated, so a plugin change asks again for the same sidebar.
type surfacesKey struct {
	rows  rowsKey
	epoch uint64
}

// surfacesJob is what one run works from. The window thread publishes a new one when the
// key changes and the run takes it once, so nothing the run reads is written again.
type surfacesJob struct {
	language i18n.Language
	key      rowsKey
	pages    []core.SettingsPage
	loaded   bool
}

// One page Effect owns catalog I/O and Core search. Rendering retains only the immutable
// projection and the native controls of explicitly visited pages. A new key (another
// query, another expanded group, an invalidated catalog) cancels the run before it, so
// only the latest request's result reaches the window.
type settingsSurfaces struct {
	pageIndices map[string]int
	labels      map[string][]string
	// contributorIDs are the plugin IDs of each page's contributors, the values of its chooser.
	contributorIDs map[string][]string
	opts           Options
	effect         *ui.EffectState[surfacesResult, surfacesKey]
	jobMu          sync.Mutex
	job            surfacesJob
	// epoch counts invalidations of the loaded catalog.
	epoch             uint64
	want              surfacesKey
	loaded, requested bool
	revision          uint64
	pages             []core.SettingsPage
	rows              []row
	failed            error
}

func newSettingsSurfaces(opts Options) settingsSurfaces {
	return settingsSurfaces{opts: opts}
}

// bind makes the effect once the surfaces have their final address.
func (s *settingsSurfaces) bind() {
	s.effect = ui.NewEffect[surfacesResult, surfacesKey](s.run)
}

func (s *settingsSurfaces) invalidate() {
	s.loaded = false
	s.requested = false
	s.epoch++
}

func (s *settingsSurfaces) request(key rowsKey) {
	want := surfacesKey{rows: key, epoch: s.epoch}
	if s.requested && want == s.want {
		return
	}
	s.want = want
	s.requested = true
	s.jobMu.Lock()
	language := i18n.English
	if s.opts.Language != nil {
		language = s.opts.Language()
	}
	s.job = surfacesJob{key: key, pages: s.pages, loaded: s.loaded, language: language}
	s.jobMu.Unlock()
}

// run is the catalog request: the settings pages once, then Core's projection of the
// sidebar for the query.
func (s *settingsSurfaces) run(parent context.Context) (surfacesResult, error) {
	s.jobMu.Lock()
	job := s.job
	s.jobMu.Unlock()
	ctx, cancel := context.WithTimeout(parent, 30*time.Second)
	defer cancel()
	opts, key := s.opts, job.key
	result := surfacesResult{pages: job.pages}
	if !job.loaded && opts.SettingsPages != nil {
		var err error
		result.pages, err = opts.SettingsPages(ctx, job.language)
		for index := range result.pages {
			page := &result.pages[index]
			if page.Kind == "compiler" {
				page.Title = i18n.SharedFormat(job.language, "desktop.sourceSettings.compilerTitle", map[string]string{"compiler": page.Title})
			}
		}
		if err != nil {
			result.err = err
			// log-exempt: 用户取消：快速搜索或关闭窗口取代旧请求。
			if !errors.Is(err, context.Canceled) {
				reportSettingsError(opts, pluginSettingsOperation, err)
			}
		}
	}
	result.pageIndices = make(map[string]int, len(result.pages))
	result.labels = make(map[string][]string, len(result.pages))
	result.ids = make(map[string][]string, len(result.pages))
	for index, page := range result.pages {
		result.pageIndices[page.Key] = index
		labels := make([]string, len(page.Contributors))
		ids := make([]string, len(page.Contributors))
		for index, contribution := range page.Contributors {
			labels[index] = contribution.Title
			ids[index] = contribution.PluginID
		}
		result.labels[page.Key] = labels
		result.ids[page.Key] = ids
	}
	items := make([]core.SettingsNavigationItem, 0, int(pageCount)+len(result.pages))
	lookup := make(map[string]row, int(pageCount)+len(result.pages))
	// An entry plugins have put pages under is a group as well, which folds them away like
	// the pages of any other group; it keeps the page of its own its row opens.
	var contributed [pageCount]bool
	for _, page := range result.pages {
		contributed[contributedParent(page.Kind)] = true
	}
	for id := pageID(0); id < pageCount; id++ {
		name := "static:" + strconv.Itoa(int(id))
		var parent *string
		if parents[id] != noPage {
			value := "static:" + strconv.Itoa(int(parents[id]))
			parent = &value
		}
		items = append(items, core.SettingsNavigationItem{ID: name, Title: titleOf(&key.text.Settings, id), Parent: parent, Group: isGroup(id) || contributed[id], Expanded: key.open[id], Keywords: pageKeywords(job.language, id)})
		lookup[name] = row{page: id}
	}
	// The build system and compiler pages are each under one row of their kind, which opens
	// the kind's page that lists them (build_kind_view.go). The row is a group that never
	// expands, so its pages are in the sidebar only while a search matches them.
	kinds := make(map[string]int)
	for _, page := range result.pages {
		kinds[page.Kind]++
	}
	buildID := "static:" + strconv.Itoa(int(pageBuild))
	for index, kind := range buildKinds {
		if kinds[kind] == 0 {
			continue
		}
		name := "kind:" + kind
		title := kindTitle(job.language, kind)
		items = append(items, core.SettingsNavigationItem{ID: name, Title: title, Parent: &buildID, Group: true})
		lookup[name] = row{page: pageBuild, kind: kind, title: title, hit: kindHit + index, count: kinds[kind]}
	}
	for index, page := range result.pages {
		parent := contributedParent(page.Kind)
		parentID := "static:" + strconv.Itoa(int(parent))
		if kindIndex(page.Kind) >= 0 {
			parentID = "kind:" + page.Kind
		}
		name := "page:" + page.Key
		items = append(items, core.SettingsNavigationItem{ID: name, Title: page.Title, Parent: &parentID, Keywords: regionKeywords(page)})
		lookup[name] = row{page: parent, dynamic: page.Key, title: page.Title, hit: int(pageCount) + index}
	}
	projected, err := opts.SettingsNavigation(ctx, items, key.query)
	if err != nil {
		result.err = err
		// log-exempt: 用户取消：快速搜索或关闭窗口取代旧请求。
		if !errors.Is(err, context.Canceled) {
			reportSettingsError(opts, pluginSettingsOperation, err)
		}
	} else if key.query != "" {
		result.rows = searchRows(projected, lookup)
	} else {
		for _, item := range projected {
			r, ok := lookup[item.ID]
			if !ok {
				continue
			}
			// A kind's row opens its page, which lists the pages under it.
			r.group = item.Group && r.kind == ""
			r.expanded = item.Expanded && r.kind == ""
			r.level = item.Level
			result.rows = append(result.rows, r)
		}
	}
	return result, nil
}

// regionKeywords are the words the settings regions of a plugin page's contributors add to
// its search (settingRegions, API-19): Core lists each region's keywords, the manifest's and
// those of the interface language.
func regionKeywords(page core.SettingsPage) string {
	var words []string
	for _, contributor := range page.Contributors {
		if contributor.Region != nil {
			words = append(words, contributor.Region.Keywords...)
		}
	}
	return strings.Join(words, " ")
}

// searchRows lists a search's hits flat, as the prototype does: every page the search matched
// or that is under a match, with the titles of its ancestors as its path. A group without a
// page of its own is only a path, since its pages are listed. A plugin's page under a kind is
// listed only when the search matched it: the kind's row stands for the others, which may be
// thousands.
func searchRows(projected []core.SettingsNavigationRow, lookup map[string]row) []row {
	var rows []row
	var matched []bool
	for _, item := range projected {
		level := int(item.Level)
		matched = append(matched[:min(level, len(matched))], item.Matched)
		inside := item.Matched
		for _, above := range matched[:level] {
			inside = inside || above
		}
		r, ok := lookup[item.ID]
		if !ok || !inside {
			continue
		}
		if r.dynamic == "" && r.kind == "" && isGroup(r.page) && !ownsPage(r.page) {
			continue
		}
		if r.dynamic != "" && r.page == pageBuild && !item.Matched {
			continue
		}
		r.path = strings.Join(item.Path, " › ")
		rows = append(rows, r)
	}
	return rows
}

// take applies the finished request on the window thread at the start of a paint and
// reports whether the sidebar's rows changed.
func (s *settingsSurfaces) take() bool {
	if s.effect == nil {
		return false
	}
	result, _, ok := s.effect.Take()
	if !ok {
		return false
	}
	s.pages, s.rows, s.failed = result.pages, result.rows, result.err
	s.pageIndices, s.labels, s.contributorIDs = result.pageIndices, result.labels, result.ids
	s.loaded = true
	s.revision++
	return true
}

// declare keeps the request for the current sidebar alive.
func (s *settingsSurfaces) declare(c ui.C) {
	if s.effect != nil && s.requested && s.opts.SettingsNavigation != nil {
		ui.Effect(c, s.effect, s.want)
	}
}

// kindCount is how many plugin pages of kind the catalog has.
func (s *settingsSurfaces) kindCount(kind string) int {
	count := 0
	for index := range s.pages {
		if s.pages[index].Kind == kind {
			count++
		}
	}
	return count
}

func (s *settingsSurfaces) selected(key string) *core.SettingsPage {
	if index, ok := s.pageIndices[key]; ok {
		return &s.pages[index]
	}
	return nil
}

func (w *window) selectSettingsPage(page pageID, key string) {
	if w.dynamicPage == key && w.sess.page == page {
		return
	}
	if w.pluginSettings.acting {
		w.pluginSettings.stop()
	}
	w.pluginSettings.blur()
	w.sess.show(page)
	if key != "" {
		// A plugin's page is listed under page, which is expanded so its row is on the screen.
		w.sess.open[page] = true
	}
	w.dynamicPage = key
	w.contributorID = ""
}

// Native field/IME objects are retained by plugin identity across surfaces.
// The cap bounds even visits to disabled marketplace packages; only clean,
// inactive objects may be evicted. Dirty forms are never silently discarded.
func (w *window) selectPluginForm(id string) bool {
	if w.pluginSettings.id == id {
		return true
	}
	if w.pluginSettings.acting {
		w.pluginSettings.stop()
	}
	w.pluginSettings.blur()
	if form := w.pluginForms[id]; form != nil {
		w.pluginSettings = form
		return true
	}
	if len(w.pluginForms) >= 64 {
		for key, form := range w.pluginForms {
			if !form.running && !form.hasDraft() {
				delete(w.pluginForms, key)
				break
			}
		}
	}
	if len(w.pluginForms) >= 64 {
		if !w.formLimitReported {
			reportSettingsError(w.ctrl.opts, pluginSettingsOperation, errors.New("plugin settings form capacity exceeded"))
			w.formLimitReported = true
		}
		return false
	}
	form := newPluginSettingsForm(w.ctrl.opts.PluginSettings)
	form.report = func(err error) { reportSettingsError(w.ctrl.opts, pluginSettingsOperation, err) }
	w.formLimitReported = false
	w.pluginSettings = form
	w.pluginForms[id] = form
	form.language = w.marketLanguage()
	form.load(id)
	return true
}

// dynamicSettingsPage is the settings page a plugin contributes to a language or a build
// system: the chosen contributor's form, under the chooser of the contributor while more than
// one contributes. The page does not repeat what its row in the group's directory says, the
// plugins that provide it and the state of a language's server. It scrolls, named by the page
// so it starts at its top each time the page is opened, and the form grows to the scroll's
// height.
func (w *window) dynamicSettingsPage(c ui.C) {
	page := w.dynamic.selected(w.dynamicPage)
	ui.Scroll(c.Key(w.dynamicPage)).Scrollbars().FillWidth().Grow(1).Shrink(1).MinHeight(0).Pad(contentPad).Gap(10).Children(func() {
		if w.dynamic.failed != nil {
			ui.Wrap(c, i18n.Shared(w.marketLanguage(), "desktop.pluginSettings.failed")).Color(w.pal.danger)
		}
		if page == nil || len(page.Contributors) == 0 {
			ui.Wrap(c, i18n.Shared(w.marketLanguage(), "desktop.pluginSettings.pageUnavailable")).Color(w.pal.muted)
			return
		}
		// A refreshed catalog may no longer list the chosen contributor: the first one stands in.
		if w.contributionOf(page) < 0 {
			w.contributorID = page.Contributors[0].PluginID
		}
		chooser := len(page.Contributors) > 1
		if chooser {
			ids := w.dynamic.contributorIDs[page.Key]
			ui.Select(c, &w.contributorID, ids, w.contributorLabel).FillWidth().Label(i18n.Shared(w.marketLanguage(), "desktop.pluginSettings.contributor"))
		}
		w.pluginSettingsPanel(c, w.contributorID, chooser)
	})
}

// contributionOf is the index of the chosen contributor on page, or -1.
func (w *window) contributionOf(page *core.SettingsPage) int {
	for index, contribution := range page.Contributors {
		if contribution.PluginID == w.contributorID {
			return index
		}
	}
	return -1
}

// contributorLabel is the title of the contributor with the plugin ID id on the open page.
func (w *window) contributorLabel(id string) string {
	if page := w.dynamic.selected(w.dynamicPage); page != nil {
		for _, contribution := range page.Contributors {
			if contribution.PluginID == id {
				return contribution.Title
			}
		}
	}
	return id
}

// pluginSettingsOperation names, in the log, a failure of the settings a plugin contributes.
const pluginSettingsOperation = "plugin_settings_surface"

// reportSettingsError hands a failure of the settings window to the host, with the operation
// that failed as the log names it, so a failure of one page is not logged as another's.
func reportSettingsError(opts Options, operation string, err error) {
	if opts.SettingsError != nil {
		opts.SettingsError(operation, err)
	} else if opts.MarketplaceError != nil {
		opts.MarketplaceError(err)
	}
}
