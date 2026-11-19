package settingswindow

import (
	"context"
	"errors"
	"strconv"
	"strings"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/searchprefs"
	"github.com/vivaui/viva/ui"
)

type searchPreferencesWork struct {
	source   SearchPreferencesSource
	baseline searchprefs.Snapshot
	stored   *core.StoredSearchPreferences
}
type searchPreferencesDraft struct {
	ready, busy, stale bool
	search, replace    ui.Field
	failure            string
	snapshot           searchprefs.Snapshot
	work               *searchPreferencesWork
	effect             *ui.EffectState[searchprefs.Snapshot, *searchPreferencesWork]
}

func (w *window) startSearchPreferences(stored *core.StoredSearchPreferences) {
	d := &w.searchDraft
	if d.busy || w.sess.finished.Load() {
		return
	}
	if d.effect == nil {
		d.effect = ui.NewEffectKeyed[searchprefs.Snapshot, *searchPreferencesWork](func(ctx context.Context, work *searchPreferencesWork) (searchprefs.Snapshot, error) {
			ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
			defer cancel()
			if work.source == nil {
				return searchprefs.Snapshot{}, errors.New("search preference source unavailable")
			}
			if work.stored == nil {
				return work.source.Load(ctx)
			}
			return work.source.Save(ctx, work.baseline, *work.stored)
		}).Sequential()
	}
	d.work = &searchPreferencesWork{source: w.ctrl.opts.SearchPreferences, baseline: d.snapshot, stored: stored}
	d.busy = true
	d.failure = ""
	w.inv.Invalidate()
}
func (w *window) takeSearchPreferences() {
	d := &w.searchDraft
	if d.effect == nil {
		return
	}
	result, err, ok := d.effect.Take()
	if !ok {
		return
	}
	d.busy = false
	if err != nil {
		d.stale = true
		d.failure = i18n.Shared(w.marketLanguage(), "desktop.search.settings.failed")
		w.reportEssentialsFailure("search_preferences", err)
		return
	}
	d.snapshot = result
	d.ready = true
	d.stale = false
	d.failure = ""
	d.search.SetText(strconv.FormatUint(result.Effective.MaxFileBytes>>20, 10))
	d.replace.SetText(strconv.FormatUint(result.Effective.ReplacementMaxFileBytes>>20, 10))
}
func (w *window) searchPage(c ui.C) {
	d := &w.searchDraft
	language := w.marketLanguage()
	if d.work == nil {
		w.startSearchPreferences(nil)
	}
	w.pageScroll(c, pageSearch, func() {
		w.card(c, i18n.Shared(language, "desktop.search.settings.limits"), i18n.Shared(language, "desktop.search.settings.limitsHelp"), func() {
			if !d.ready && d.busy {
				ui.Text(c, i18n.Shared(language, "quickOpen.searching")).Muted()
				return
			}
			w.settingsRow(c, i18n.Shared(language, "desktop.search.settings.search"), i18n.Shared(language, "desktop.search.settings.searchHelp"), func() {
				ui.TextField(c.Part("search-budget"), &d.search, i18n.Shared(language, "desktop.search.settings.search"), "").Width(100).Disabled(d.busy)
			})
			w.settingsRow(c, i18n.Shared(language, "desktop.search.settings.replace"), i18n.Shared(language, "desktop.search.settings.replaceHelp"), func() {
				ui.TextField(c.Part("replace-budget"), &d.replace, i18n.Shared(language, "desktop.search.settings.replace"), "").Width(100).Disabled(d.busy)
			})
			if d.ready {
				ui.Text(c, i18n.SharedFormat(language, "desktop.search.settings.range", map[string]string{"maximum": strconv.FormatUint(d.snapshot.Effective.MaximumFileBytes>>20, 10)})).FontSize(12).Muted()
				ui.Text(c, d.snapshot.Path).FontSize(11).Muted().Ellipsis()
			}
			if d.failure != "" {
				ui.Wrap(c, d.failure).Color(w.pal.danger)
			}
			ui.Row(c).Gap(8).Children(func() {
				if ui.Button(c, i18n.Shared(language, "desktop.buildSettings.apply")).Disabled(!d.ready || d.busy || d.stale).Clicked() {
					w.applySearchPreferences(false)
				}
				if ui.Button(c.Part("search-reset"), w.text.Settings.RestoreDefaults).Outline().Disabled(!d.ready || d.busy || d.stale).Clicked() {
					w.applySearchPreferences(true)
				}
				if ui.Button(c, i18n.Shared(language, "ui.refresh")).Outline().Disabled(d.busy).Clicked() {
					w.startSearchPreferences(nil)
				}
			})
		})
	})
}
func (w *window) applySearchPreferences(reset bool) {
	d := &w.searchDraft
	if !d.ready || d.busy || d.stale || w.sess.finished.Load() {
		return
	}
	stored := core.StoredSearchPreferences{}
	if !reset {
		search, err := strconv.ParseUint(strings.TrimSpace(d.search.Text()), 10, 64)
		replace, replaceErr := strconv.ParseUint(strings.TrimSpace(d.replace.Text()), 10, 64)
		if err != nil || replaceErr != nil || search == 0 || replace == 0 || search > d.snapshot.Effective.MaximumFileBytes>>20 || replace > d.snapshot.Effective.MaximumFileBytes>>20 {
			d.failure = i18n.Shared(w.marketLanguage(), "desktop.search.settings.invalid")
			w.reportEssentialsFailure("search_preferences", errors.New("invalid_file_budget"))
			return
		}
		search, replace = search<<20, replace<<20
		stored = core.StoredSearchPreferences{MaxFileBytes: &search, ReplacementMaxFileBytes: &replace}
	}
	w.startSearchPreferences(&stored)
}
