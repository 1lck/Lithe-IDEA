package settingswindow

import (
	"context"
	"maps"
	"slices"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// steppingDraft is what the stepping card shows for one adapter before Apply: the class
// patterns as the text area holds them, one per line, and the switches.
type steppingDraft struct {
	patterns               string
	skipSynthetics         bool
	skipStaticInitializers bool
	skipConstructors       bool
	hideFilteredFrames     bool
}

func draftOf(filters core.DebugSteppingFilters) steppingDraft {
	return steppingDraft{
		patterns:               strings.Join(filters.ClassNameFilters, "\n"),
		skipSynthetics:         filters.SkipSynthetics,
		skipStaticInitializers: filters.SkipStaticInitializers,
		skipConstructors:       filters.SkipConstructors,
		hideFilteredFrames:     filters.HideFilteredStackFrames,
	}
}

// filters is the draft as a policy: one pattern per non-blank line. Core trims, sorts and
// removes duplicates when the policy is applied.
func (d steppingDraft) filters() core.DebugSteppingFilters {
	patterns := []string{}
	for _, line := range strings.Split(d.patterns, "\n") {
		if line = strings.TrimSpace(line); line != "" {
			patterns = append(patterns, line)
		}
	}
	return core.DebugSteppingFilters{
		ClassNameFilters:        patterns,
		SkipSynthetics:          d.skipSynthetics,
		SkipStaticInitializers:  d.skipStaticInitializers,
		SkipConstructors:        d.skipConstructors,
		HideFilteredStackFrames: d.hideFilteredFrames,
	}
}

// sameFilters compares two policies by what they do.
func sameFilters(a, b core.DebugSteppingFilters) bool {
	return slices.Equal(a.ClassNameFilters, b.ClassNameFilters) && a.SkipSynthetics == b.SkipSynthetics &&
		a.SkipStaticInitializers == b.SkipStaticInitializers && a.SkipConstructors == b.SkipConstructors &&
		a.HideFilteredStackFrames == b.HideFilteredStackFrames
}

// steppingSave is a policy Core has checked, ready to be stored for adapter.
type steppingSave struct {
	adapter string
	filters core.DebugSteppingFilters
}

// steppingState is the Build page's stepping card: the installed adapters that take
// stepping filters, the one shown and the drafts. Only the window thread reads or writes
// the fields. The list loads the first time the page is drawn; Apply has Core check the
// draft (debug.steppingFilters) and stores what it returns. Opening the page writes nothing.
type steppingState struct {
	loadEffect *ui.EffectState[[]SteppingAdapter, int]
	saveEffect *ui.EffectState[steppingSave, int]
	loadKey    int
	saveKey    int
	pending    steppingSave

	loading, loaded, saving bool
	loadErr, saveErr        error

	adapters []SteppingAdapter
	selected string
	// drafts are the card's edits by adapter. Viva binds a switch or text area to the
	// address of its value, so each draft stays at one address while it is shown.
	drafts map[string]*steppingDraft
}

func newSteppingState(load func(context.Context) ([]SteppingAdapter, error), normalize func(context.Context, string, core.DebugSteppingFilters) (core.DebugSteppingFilters, error)) *steppingState {
	s := &steppingState{drafts: make(map[string]*steppingDraft)}
	if load == nil || normalize == nil {
		return s
	}
	s.loadEffect = ui.NewEffect[[]SteppingAdapter, int](load)
	s.saveEffect = ui.NewEffect[steppingSave, int](func(ctx context.Context) (steppingSave, error) {
		request := s.pending
		filters, err := normalize(ctx, request.adapter, request.filters)
		return steppingSave{adapter: request.adapter, filters: filters}, err
	})
	return s
}

// available says whether the window can list and store stepping policies.
func (s *steppingState) available() bool { return s.loadEffect != nil }

func (s *steppingState) beginLoad() {
	if !s.available() || s.loading || s.loaded {
		return
	}
	s.loadKey++
	s.loading, s.loadErr = true, nil
}

func (s *steppingState) beginSave(adapter string, filters core.DebugSteppingFilters) {
	if !s.available() || s.saving {
		return
	}
	s.pending = steppingSave{adapter: adapter, filters: filters}
	s.saveKey++
	s.saving, s.saveErr = true, nil
}

// take applies a finished load, and returns a finished save for the window to store.
func (s *steppingState) take() (steppingSave, bool) {
	if !s.available() {
		return steppingSave{}, false
	}
	if adapters, err, ok := s.loadEffect.Take(); ok {
		s.loading, s.loaded, s.loadErr = false, true, err
		s.adapters = adapters
		if len(adapters) > 0 && !slices.ContainsFunc(adapters, func(a SteppingAdapter) bool { return a.ID == s.selected }) {
			s.selected = adapters[0].ID
		}
	}
	if saved, err, ok := s.saveEffect.Take(); ok {
		s.saving, s.saveErr = false, err
		if err == nil {
			draft := draftOf(saved.filters)
			s.drafts[saved.adapter] = &draft
			return saved, true
		}
	}
	return steppingSave{}, false
}

func (s *steppingState) declare(c ui.C) {
	if !s.available() {
		return
	}
	if s.loadKey != 0 {
		ui.Effect(c, s.loadEffect, s.loadKey)
	}
	if s.saveKey != 0 {
		ui.Effect(c, s.saveEffect, s.saveKey)
	}
}

// effectiveFilters is the policy adapter uses now: the user's, else its declared defaults.
func (w *window) effectiveFilters(adapter SteppingAdapter) (core.DebugSteppingFilters, bool) {
	if filters, ok := w.sess.values.SteppingFilters[adapter.ID]; ok {
		return filters, true
	}
	return adapter.Defaults, false
}

// setSteppingFilters stores the policy of one adapter, or removes it when filters is nil,
// and hands the change to the settings owner at once.
func (w *window) setSteppingFilters(adapter string, filters *core.DebugSteppingFilters) {
	if w.sess.finished.Load() {
		return
	}
	stored := make(map[string]core.DebugSteppingFilters, len(w.sess.values.SteppingFilters)+1)
	for id, value := range w.sess.values.SteppingFilters {
		if id != adapter {
			stored[id] = value
		}
	}
	if filters != nil {
		stored[adapter] = *filters
	}
	w.sess.values.SteppingFilters = stored
	if w.ctrl.opts.SetSteppingFilters != nil {
		w.ctrl.opts.SetSteppingFilters(adapter, filters)
	}
}

// resetSteppingFilters removes every stored policy, for Restore Defaults.
func (w *window) resetSteppingFilters() {
	for _, id := range slices.Sorted(maps.Keys(w.sess.values.SteppingFilters)) {
		w.setSteppingFilters(id, nil)
	}
	clear(w.stepping.drafts)
}

// steppingCard is the Build page's card for the stepping filters of the installed debug
// adapters that take them: the classes not to step into, the methods to step over and
// whether the call stack collapses the frames the patterns match. A change takes effect
// at the next debug session.
func (w *window) steppingCard(c ui.C, language i18n.Language) {
	s := w.stepping
	if !s.available() {
		return
	}
	s.beginLoad()
	c = c.Part("stepping")
	w.card(c, i18n.Shared(language, "desktop.settings.stepping.title"), i18n.Shared(language, "desktop.settings.stepping.description"), func() {
		ui.Column(c).FillWidth().Gap(8).Children(func() {
			switch {
			case s.loading:
				ui.Text(c, i18n.Shared(language, "desktop.settings.stepping.loading")).FontSize(12).Color(w.pal.muted)
				return
			case s.loadErr != nil && len(s.adapters) == 0:
				ui.Wrap(c, i18n.SharedFormat(language, "desktop.settings.stepping.loadFailed", map[string]string{"reason": s.loadErr.Error()})).FontSize(12).Color(w.pal.danger)
				return
			case len(s.adapters) == 0:
				ui.Wrap(c, i18n.Shared(language, "desktop.settings.stepping.none")).FontSize(12).Color(w.pal.muted)
				return
			}
			w.steppingAdapter(c, language)
		})
	})
}

func (w *window) steppingAdapter(c ui.C, language i18n.Language) {
	s := w.stepping
	if len(s.adapters) > 1 {
		ids := make([]string, len(s.adapters))
		names := make(map[string]string, len(s.adapters))
		for i, adapter := range s.adapters {
			ids[i], names[adapter.ID] = adapter.ID, adapter.Name
		}
		ui.Row(c).FillWidth().Height(28).Items(ui.Center).Gap(12).Children(func() {
			ui.Text(c, i18n.Shared(language, "desktop.settings.stepping.adapter")).FontSize(12).Color(w.pal.text).Grow(1).MinWidth(0).Ellipsis()
			ui.Select(c.Part("adapter"), &s.selected, ids, func(id string) string { return names[id] }).Width(selectWidth).
				Label(i18n.Shared(language, "desktop.settings.stepping.adapter"))
		})
	}
	i := slices.IndexFunc(s.adapters, func(a SteppingAdapter) bool { return a.ID == s.selected })
	if i < 0 {
		return
	}
	adapter := s.adapters[i]
	effective, customized := w.effectiveFilters(adapter)
	draft := s.drafts[adapter.ID]
	if draft == nil {
		fresh := draftOf(effective)
		draft = &fresh
		s.drafts[adapter.ID] = draft
	}
	k := c.Key(adapter.ID)
	if len(s.adapters) == 1 {
		ui.Text(k, adapter.Name).FontSize(12).Weight(gfx.WeightSemibold).Color(w.pal.text)
	}
	ui.Text(k, i18n.Shared(language, "desktop.settings.stepping.classFilters")).FontSize(12).Color(w.pal.text)
	ui.TextArea(k.Part("patterns"), &draft.patterns, i18n.Shared(language, "desktop.settings.stepping.classFilters"), "").
		FillWidth().Height(140).Disabled(s.saving)
	ui.Wrap(k, i18n.Shared(language, "desktop.settings.stepping.classFiltersHelp")).FontSize(11).Color(w.pal.muted)
	ui.Switch(k.Part("synthetics"), &draft.skipSynthetics, i18n.Shared(language, "desktop.settings.stepping.skipSynthetics"))
	ui.Switch(k.Part("static"), &draft.skipStaticInitializers, i18n.Shared(language, "desktop.settings.stepping.skipStaticInitializers"))
	ui.Switch(k.Part("constructors"), &draft.skipConstructors, i18n.Shared(language, "desktop.settings.stepping.skipConstructors"))
	ui.Switch(k.Part("hide"), &draft.hideFilteredFrames, i18n.Shared(language, "desktop.settings.stepping.hideFilteredFrames"))
	dirty := !sameFilters(draft.filters(), effective)
	ui.Row(k).FillWidth().Gap(8).Items(ui.Center).Children(func() {
		status := i18n.Shared(language, "desktop.settings.stepping.usingDefaults")
		if customized {
			status = i18n.Shared(language, "desktop.settings.stepping.customized")
		}
		if s.saving {
			status = i18n.Shared(language, "desktop.settings.stepping.saving")
		}
		ui.Text(k, status).FontSize(12).Color(w.pal.muted).Grow(1).MinWidth(0).Ellipsis()
		if ui.Button(k.Part("restore"), i18n.Shared(language, "desktop.settings.stepping.restoreDefaults")).Outline().
			Disabled(s.saving || (!customized && !dirty)).Clicked() {
			delete(s.drafts, adapter.ID)
			s.saveErr = nil
			if customized {
				w.setSteppingFilters(adapter.ID, nil)
			}
		}
		if ui.Button(k.Part("apply"), i18n.Shared(language, "desktop.settings.stepping.apply")).Disabled(s.saving || !dirty).Clicked() {
			s.beginSave(adapter.ID, draft.filters())
		}
	})
	if s.saveErr != nil {
		ui.Wrap(k, i18n.SharedFormat(language, "desktop.settings.stepping.saveFailed", map[string]string{"reason": s.saveErr.Error()})).FontSize(12).Color(w.pal.danger)
	}
}
