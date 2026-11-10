package settingswindow

import (
	"context"
	"errors"
	"strconv"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/ui"
)

type surfacesResult struct {
	pageIndices map[string]int
	labels      map[string][]string
	generation  uint64
	pages       []core.SettingsPage
	rows        []row
	err         error
}

// One bounded worker owns catalog I/O and Core search. Rendering retains only
// the immutable projection and the native controls of explicitly visited pages.
type settingsSurfaces struct {
	pageIndices                         map[string]int
	labels                              map[string][]string
	opts                                Options
	wake                                func()
	results                             chan surfacesResult
	cancel                              context.CancelFunc
	generation                          uint64
	revision                            uint64
	running, pending, loaded, requested bool
	key                                 rowsKey
	pages                               []core.SettingsPage
	rows                                []row
	failed                              error
}

func newSettingsSurfaces(opts Options, wake func()) settingsSurfaces {
	return settingsSurfaces{opts: opts, wake: wake, results: make(chan surfacesResult, 1)}
}

func (s *settingsSurfaces) invalidate() {
	s.loaded = false
	s.requested = false
	s.generation++
	if s.cancel != nil {
		s.cancel()
	}
}

func (s *settingsSurfaces) request(key rowsKey) {
	if s.requested && key == s.key {
		return
	}
	s.key = key
	s.requested = true
	s.pending = true
	s.generation++
	if s.cancel != nil {
		s.cancel()
	}
	s.launch()
}

func (s *settingsSurfaces) launch() {
	if s.running || !s.pending || s.opts.SettingsNavigation == nil {
		return
	}
	s.running = true
	s.pending = false
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	s.cancel = cancel
	key, generation, pages, loaded, opts, results, wake := s.key, s.generation, s.pages, s.loaded, s.opts, s.results, s.wake
	go func() {
		defer cancel()
		result := surfacesResult{generation: generation, pages: pages}
		if !loaded && opts.SettingsPages != nil {
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
		for index, page := range result.pages {
			result.pageIndices[page.Key] = index
			labels := make([]string, len(page.Contributors))
			for index, contribution := range page.Contributors {
				labels[index] = contribution.Title
			}
			result.labels[page.Key] = labels
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
		results <- result
		if wake != nil {
			wake()
		}
	}()
}

func (s *settingsSurfaces) drain() bool {
	select {
	case result := <-s.results:
		s.running = false
		s.cancel = nil
		if result.generation != s.generation {
			s.launch()
			return false
		}
		s.pages, s.rows, s.failed = result.pages, result.rows, result.err
		s.pageIndices, s.labels = result.pageIndices, result.labels
		s.loaded = true
		s.revision++
		return true
	default:
		return false
	}
}

func (s *settingsSurfaces) selected(key string) *core.SettingsPage {
	if index, ok := s.pageIndices[key]; ok {
		return &s.pages[index]
	}
	return nil
}

func (s *settingsSurfaces) close() {
	s.pending = false
	s.generation++
	if s.cancel != nil {
		s.cancel()
	}
}

func (w *window) selectSettingsPage(page pageID, key string) {
	if w.dynamicPage == key && w.sess.page == page {
		return
	}
	if w.pluginSettings.acting && w.pluginSettings.cancel != nil {
		w.pluginSettings.cancel()
	}
	w.pluginSettings.blur()
	w.sess.show(page)
	w.dynamicPage = key
	w.contribution = 0
	w.contributorID = ""
	w.contributionFor = 0
	w.contributor.Open = false
}

// Native field/IME objects are retained by plugin identity across surfaces.
// The cap bounds even visits to disabled marketplace packages; only clean,
// inactive objects may be evicted. Dirty forms are never silently discarded.
func (w *window) selectPluginForm(id string) bool {
	if w.pluginSettings.id == id {
		return true
	}
	if w.pluginSettings.acting && w.pluginSettings.cancel != nil {
		w.pluginSettings.cancel()
	}
	w.pluginSettings.blur()
	if form := w.pluginForms[id]; form != nil {
		w.pluginSettings = form
		return true
	}
	if len(w.pluginForms) >= 64 {
		for key, form := range w.pluginForms {
			if !form.running && !form.hasDraft() {
				form.close()
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
	form := newPluginSettingsForm(w.ctrl.opts.PluginSettings, w.inv.Invalidate)
	form.report = func(err error) { reportSettingsError(w.ctrl.opts, err) }
	w.formLimitReported = false
	w.pluginSettings = &form
	w.pluginForms[id] = &form
	form.load(id)
	return true
}

var settingsCatalogReload = tree.ID(root, "settings-catalog-reload")

var contributedPluginID = tree.Sub(root, tree.Name("contributed-settings-plugin"))

func (w *window) drawDynamicSettings(f *ui.Frame) {
	page := w.dynamic.selected(w.dynamicPage)
	f.Column().FillWidth().Grow(1).MinHeight(0).Pad(contentPad).Gap(10).Children(func() {
		if w.dynamic.failed != nil {
			f.Wrap(i18n.Shared(w.marketLanguage(), "desktop.pluginSettings.failed")).Color(w.pal.danger)
		}
		if page == nil || len(page.Contributors) == 0 {
			f.Wrap(i18n.Shared(w.marketLanguage(), "desktop.pluginSettings.pageUnavailable")).Color(w.pal.muted)
			return
		}
		if w.contributionFor != w.dynamic.revision {
			w.contribution = 0
			for index, contribution := range page.Contributors {
				if contribution.PluginID == w.contributorID {
					w.contribution = index
					break
				}
			}
			w.contributionFor = w.dynamic.revision
		}
		labels := w.dynamic.labels[page.Key]
		if index, ok := f.Select(contributedPluginID, &w.contributor, labels, w.contribution).FillWidth().Label(i18n.Shared(w.marketLanguage(), "desktop.pluginSettings.contributor")).Picked(); ok {
			w.contribution = index
		}
		w.contributorID = page.Contributors[w.contribution].PluginID
		w.drawPluginSettings(f, w.contributorID)
	})
}

func reportSettingsError(opts Options, err error) {
	if opts.SettingsError != nil {
		opts.SettingsError(err)
	} else if opts.MarketplaceError != nil {
		opts.MarketplaceError(err)
	}
}
