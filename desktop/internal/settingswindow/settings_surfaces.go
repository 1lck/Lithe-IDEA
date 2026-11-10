package settingswindow

import (
	"context"
	"errors"
	"strconv"
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
	key    rowsKey
	pages  []core.SettingsPage
	loaded bool
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
	s.job = surfacesJob{key: key, pages: s.pages, loaded: s.loaded}
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
		result.pages, err = opts.SettingsPages(ctx)
		if err != nil {
			result.err = err
			// log-exempt: 用户取消：快速搜索或关闭窗口取代旧请求。
			if !errors.Is(err, context.Canceled) {
				reportSettingsError(opts, err)
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
	for id := pageID(0); id < pageCount; id++ {
		name := "static:" + strconv.Itoa(int(id))
		var parent *string
		if parents[id] != noPage {
			value := "static:" + strconv.Itoa(int(parents[id]))
			parent = &value
		}
		items = append(items, core.SettingsNavigationItem{ID: name, Title: titleOf(&key.text.Settings, id), Parent: parent, Group: isGroup(id), Expanded: key.open[id]})
		lookup[name] = row{page: id}
	}
	for index, page := range result.pages {
		parent := pageLanguages
		if page.Kind == "buildSystem" {
			parent = pageBuild
		}
		parentID := "static:" + strconv.Itoa(int(parent))
		name := "page:" + page.Key
		items = append(items, core.SettingsNavigationItem{ID: name, Title: page.Title, Parent: &parentID})
		lookup[name] = row{page: parent, dynamic: page.Key, title: page.Title, hit: int(pageCount) + index}
	}
	projected, err := opts.SettingsNavigation(ctx, items, key.query)
	if err != nil {
		result.err = err
		// log-exempt: 用户取消：快速搜索或关闭窗口取代旧请求。
		if !errors.Is(err, context.Canceled) {
			reportSettingsError(opts, err)
		}
	} else {
		for _, item := range projected {
			r, ok := lookup[item.ID]
			if !ok {
				continue
			}
			r.group = item.Group
			r.expanded = item.Expanded
			r.level = item.Level
			result.rows = append(result.rows, r)
		}
	}
	return result, nil
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
			reportSettingsError(w.ctrl.opts, errors.New("plugin settings form capacity exceeded"))
			w.formLimitReported = true
		}
		return false
	}
	form := newPluginSettingsForm(w.ctrl.opts.PluginSettings)
	form.report = func(err error) { reportSettingsError(w.ctrl.opts, err) }
	w.formLimitReported = false
	w.pluginSettings = form
	w.pluginForms[id] = form
	form.load(id)
	return true
}

// dynamicSettingsPage is the settings page a plugin contributes to a language or a build
// system: the contributors' chooser above the selected contributor's form.
func (w *window) dynamicSettingsPage(c ui.C) {
	page := w.dynamic.selected(w.dynamicPage)
	ui.Column(c).FillWidth().Grow(1).MinHeight(0).Pad(contentPad).Gap(10).Children(func() {
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
		ids := w.dynamic.contributorIDs[page.Key]
		ui.Select(c, &w.contributorID, ids, w.contributorLabel).FillWidth().Label(i18n.Shared(w.marketLanguage(), "desktop.pluginSettings.contributor"))
		w.pluginSettingsPanel(c, w.contributorID)
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

func reportSettingsError(opts Options, err error) {
	if opts.SettingsError != nil {
		opts.SettingsError(err)
	} else if opts.MarketplaceError != nil {
		opts.MarketplaceError(err)
	}
}
