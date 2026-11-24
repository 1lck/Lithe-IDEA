package settingswindow

import (
	"context"
	"maps"
	"slices"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// The Debuggers page follows the prototype docs/design/build-execution-settings.html: the
// installed debug adapters that take stepping filters on the left, the chosen one's tabs on
// the right. Its edits are drafts the window footer's Apply writes, with the Toolchains
// page's, and they take effect at the next debug session.

const (
	// debuggerListWidth is the prototype's width of the adapter list.
	debuggerListWidth = 280
	// debuggerRow is the prototype's height of an adapter row.
	debuggerRow = 44
	// steppingTab is the only tab of an adapter so far; the other debug settings join it.
	steppingTab = "stepping"
)

// steppingDraft is the page's working copy of one adapter's policy: the patterns as a list
// and the switches. Viva binds a switch to the address of its value, so each draft stays at
// one address for the window's life.
type steppingDraft struct {
	patterns               []string
	skipSynthetics         bool
	skipStaticInitializers bool
	skipConstructors       bool
	hideFilteredFrames     bool
}

func draftOf(filters core.DebugSteppingFilters) steppingDraft {
	return steppingDraft{
		patterns:               slices.Clone(filters.ClassNameFilters),
		skipSynthetics:         filters.SkipSynthetics,
		skipStaticInitializers: filters.SkipStaticInitializers,
		skipConstructors:       filters.SkipConstructors,
		hideFilteredFrames:     filters.HideFilteredStackFrames,
	}
}

// filters is the draft as a policy: its non-blank patterns. Core trims, sorts and removes
// duplicates when the policy is applied.
func (d steppingDraft) filters() core.DebugSteppingFilters {
	patterns := []string{}
	for _, pattern := range d.patterns {
		if pattern = strings.TrimSpace(pattern); pattern != "" {
			patterns = append(patterns, pattern)
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

// steppingState is the Debuggers page: the installed adapters that take stepping filters, the
// one shown, the list's query and the drafts. Only the window thread reads or writes the
// fields. The list loads the first time a page needs it; Apply has Core check a draft
// (debug.steppingFilters) and stores what it returns. Opening the page writes nothing.
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
	query    string
	// add is the pattern field's text; it empties when another adapter is chosen.
	add  string
	tab  string
	list ui.ListState
	// drafts are the working copies by adapter, made when an adapter is first shown.
	drafts map[string]*steppingDraft
}

func newSteppingState(load func(context.Context) ([]SteppingAdapter, error), normalize func(context.Context, string, core.DebugSteppingFilters) (core.DebugSteppingFilters, error)) *steppingState {
	s := &steppingState{drafts: make(map[string]*steppingDraft), tab: steppingTab}
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

func (s *steppingState) beginSave(adapter string, filters core.DebugSteppingFilters) bool {
	if !s.available() || s.saving {
		return false
	}
	s.pending = steppingSave{adapter: adapter, filters: filters}
	s.saveKey++
	s.saving, s.saveErr = true, nil
	return true
}

// take applies a finished load, and returns a finished save for the window to store: done
// says one finished, err that Core refused it.
func (s *steppingState) take() (saved steppingSave, err error, done bool) {
	if !s.available() {
		return steppingSave{}, nil, false
	}
	if adapters, err, ok := s.loadEffect.Take(); ok {
		s.loading, s.loaded, s.loadErr = false, true, err
		s.adapters = adapters
		if len(adapters) > 0 && s.adapter(s.selected) == nil {
			s.selected = adapters[0].ID
		}
	}
	if saved, err, ok := s.saveEffect.Take(); ok {
		s.saving, s.saveErr = false, err
		return saved, err, true
	}
	return steppingSave{}, nil, false
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

// adapter is the listed adapter with the ID, or nil.
func (s *steppingState) adapter(id string) *SteppingAdapter {
	for index := range s.adapters {
		if s.adapters[index].ID == id {
			return &s.adapters[index]
		}
	}
	return nil
}

// effectiveFilters is the policy adapter uses now: the user's, else its declared defaults.
func (w *window) effectiveFilters(adapter SteppingAdapter) (core.DebugSteppingFilters, bool) {
	if filters, ok := w.sess.values.SteppingFilters[adapter.ID]; ok {
		return filters, true
	}
	return adapter.Defaults, false
}

// steppingDraftOf is the adapter's working copy, made from its stored policy when it has none.
func (w *window) steppingDraftOf(adapter SteppingAdapter) *steppingDraft {
	draft := w.stepping.drafts[adapter.ID]
	if draft == nil {
		effective, _ := w.effectiveFilters(adapter)
		fresh := draftOf(effective)
		draft = &fresh
		w.stepping.drafts[adapter.ID] = draft
	}
	return draft
}

// steppingChanged says whether the adapter's working copy differs from what it uses now.
func (w *window) steppingChanged(adapter SteppingAdapter) bool {
	draft := w.stepping.drafts[adapter.ID]
	if draft == nil {
		return false
	}
	effective, _ := w.effectiveFilters(adapter)
	return !sameFilters(draft.filters(), effective)
}

// steppingPending are the adapters with a change to apply, in the list's order.
func (w *window) steppingPending() []string {
	var ids []string
	for _, adapter := range w.stepping.adapters {
		if w.steppingChanged(adapter) {
			ids = append(ids, adapter.ID)
		}
	}
	return ids
}

// setSteppingFilters stores the policy of one adapter, or removes it when filters is nil,
// and hands the change to the settings owner at once. The working copy becomes the stored
// policy.
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
	if draft := w.stepping.drafts[adapter]; draft != nil {
		if listed := w.stepping.adapter(adapter); listed != nil {
			effective, _ := w.effectiveFilters(*listed)
			*draft = draftOf(effective)
		}
	}
	if w.ctrl.opts.SetSteppingFilters != nil {
		w.ctrl.opts.SetSteppingFilters(adapter, filters)
	}
}

// resetSteppingFilters removes every stored policy and every draft, for Restore Defaults.
func (w *window) resetSteppingFilters() {
	for _, id := range slices.Sorted(maps.Keys(w.sess.values.SteppingFilters)) {
		w.setSteppingFilters(id, nil)
	}
	for id, draft := range w.stepping.drafts {
		if adapter := w.stepping.adapter(id); adapter != nil {
			*draft = draftOf(adapter.Defaults)
		}
	}
}

// beginSteppingApply starts writing one adapter's draft: a draft equal to the plugin's
// defaults removes the stored policy at once, any other goes to Core first. It reports
// whether a request is out.
func (w *window) beginSteppingApply(id string) bool {
	adapter := w.stepping.adapter(id)
	if adapter == nil || !w.steppingChanged(*adapter) {
		return false
	}
	filters := w.stepping.drafts[id].filters()
	if sameFilters(filters, adapter.Defaults) {
		w.setSteppingFilters(id, nil)
		return false
	}
	return w.stepping.beginSave(id, filters)
}

// steppingFeatures are the switches of a policy with their words and help.
func steppingFeatures(language i18n.Language, draft *steppingDraft) []struct {
	key, label, help string
	value            *bool
} {
	return []struct {
		key, label, help string
		value            *bool
	}{
		{"synthetics", i18n.Shared(language, "desktop.settings.stepping.skipSynthetics"), i18n.Shared(language, "desktop.buildSettings.skipSyntheticsHelp"), &draft.skipSynthetics},
		{"static", i18n.Shared(language, "desktop.settings.stepping.skipStaticInitializers"), i18n.Shared(language, "desktop.buildSettings.skipStaticInitializersHelp"), &draft.skipStaticInitializers},
		{"constructors", i18n.Shared(language, "desktop.settings.stepping.skipConstructors"), i18n.Shared(language, "desktop.buildSettings.skipConstructorsHelp"), &draft.skipConstructors},
		{"hide", i18n.Shared(language, "desktop.settings.stepping.hideFilteredFrames"), i18n.Shared(language, "desktop.buildSettings.hideFilteredFramesHelp"), &draft.hideFilteredFrames},
	}
}

// steppingPluginName is the name of the plugin that declares the adapter.
func steppingPluginName(adapter SteppingAdapter) string {
	switch {
	case adapter.PluginName != "":
		return adapter.PluginName
	case adapter.PluginID != "":
		return adapter.PluginID
	default:
		// The tile needs a name to draw its letters; an adapter no plugin claims has its own.
		return adapter.Name
	}
}

// debuggersPage is the Debuggers page under Build, Execution, Deployment.
func (w *window) debuggersPage(c ui.C) {
	s := w.stepping
	if !s.available() {
		w.unavailablePage(c)
		return
	}
	language := w.marketLanguage()
	s.beginLoad()
	b := &w.bp
	switch {
	case !s.loaded:
		w.toolchainsEmpty(c, i18n.Shared(language, "desktop.settings.stepping.loading"))
		return
	case s.loadErr != nil && len(s.adapters) == 0:
		w.toolchainsEmpty(c, i18n.SharedFormat(language, "desktop.settings.stepping.loadFailed", map[string]string{"reason": s.loadErr.Error()}))
		return
	case len(s.adapters) == 0:
		w.toolchainsEmpty(c, i18n.Shared(language, "desktop.settings.stepping.none"))
		return
	}
	width := float32(debuggerListWidth)
	if room := w.extent - 1 - toolchainDetailMin; room < width {
		width = max(220, room)
	}
	ui.Row(c).FillWidth().Grow(1).Shrink(1).MinHeight(0).Background(b.surface).Children(func() {
		ui.Column(c).Width(width).Shrink(0).FillHeight().MinHeight(0).Children(func() {
			ui.Row(c).FillWidth().Shrink(0).PadX(10).PadY(10).Children(func() {
				label := i18n.Shared(language, "desktop.buildSettings.debuggerFilter")
				w.filterField(c.Part("filter"), &s.query, label, label, true)
			})
			ui.Row(c).FillWidth().Height(1).Shrink(0).Background(b.line)
			w.debuggerList(c.Part("list"), language)
			ui.Row(c).FillWidth().Height(1).Shrink(0).Background(b.line)
			ui.Row(c).FillWidth().Shrink(0).PadX(12).PadY(5).Children(func() {
				ui.Text(c, debuggerCount(language, len(s.adapters))).
					FontSize(11).Color(b.faint).Ellipsis()
			})
		})
		ui.Row(c).Width(1).Shrink(0).FillHeight().Background(b.line)
		ui.Scroll(c.Key("debugger:"+s.selected)).Scrollbars().Grow(1).Shrink(1).MinWidth(0).FillHeight().
			PadSides(buildPagePadTop, buildPagePadX, buildPagePadEnd, buildPagePadX).Children(func() {
			if adapter := s.adapter(s.selected); adapter != nil {
				w.debuggerDetail(c, language, *adapter)
			}
		})
	})
}

// debuggerList is the adapters whose name or plugin holds the query.
func (w *window) debuggerList(c ui.C, language i18n.Language) {
	s := w.stepping
	b := &w.bp
	query := strings.ToLower(strings.TrimSpace(s.query))
	var shown []SteppingAdapter
	for _, adapter := range s.adapters {
		if query == "" || strings.Contains(strings.ToLower(adapter.Name), query) || strings.Contains(strings.ToLower(steppingPluginName(adapter)), query) {
			shown = append(shown, adapter)
		}
	}
	if len(shown) == 0 {
		ui.Column(c).FillWidth().Grow(1).Shrink(1).MinHeight(0).PadSides(50, 20, 50, 20).Items(ui.Center).Children(func() {
			ui.Wrap(c, i18n.Shared(language, "desktop.buildSettings.debuggerNoMatches")).FontSize(buildSmall).Color(b.faint).TextCenter()
		})
		return
	}
	s.list.Key = nil
	s.list.Header = nil
	s.list.Label = func(i int) string {
		if i < 0 || i >= len(shown) {
			return ""
		}
		return shown[i].Name
	}
	at := slices.IndexFunc(shown, func(adapter SteppingAdapter) bool { return adapter.ID == s.selected })
	if s.list.Selected() != at {
		s.list.Select(at)
		if at >= 0 {
			s.list.ScrollIntoView(at)
		}
	}
	ui.List(c, &s.list, len(shown), func(r ui.ListRow) {
		adapter := shown[r.Index]
		k := r.C
		changed := w.steppingChanged(adapter)
		_, stored := w.effectiveFilters(adapter)
		r.Element.Height(debuggerRow).PadSides(0, 12, 0, 14).Gap(9).Items(ui.Center)
		// List also measures the row without a hit identity.
		if !r.ID.IsZero() {
			r.Element.Hover(ui.Look{}.Background(b.hover))
		}
		if r.Selected() {
			r.Element.Background(b.sel)
		}
		r.Element.Children(func() {
			if changed {
				ui.Row(k).Absolute().Left(4).Top(19).Size(6, 6).Radius(3).Background(b.accent)
			}
			w.pluginTile(k, steppingPluginName(adapter), 20)
			ui.Column(k).Grow(1).Shrink(1).MinWidth(0).Children(func() {
				ui.Row(k).FillWidth().Gap(6).Items(ui.Center).Children(func() {
					ui.Text(c, adapter.Name).FontSize(buildFont).Weight(gfx.WeightSemibold).Color(b.text).Shrink(1).Ellipsis()
					ui.Spacer(c)
					if stored || changed {
						w.tag(k, tagBlue, i18n.Shared(language, "desktop.settings.stepping.customized"))
					}
				})
				ui.Row(k).FillWidth().Height(2).Shrink(0)
				ui.Text(c, steppingPluginName(adapter)).FontSize(11).Color(b.faint).Ellipsis()
			})
		})
	}).Scrollbars().FillWidth().Grow(1).Shrink(1).MinHeight(0).Label(i18n.Shared(language, "desktop.buildSettings.debuggers"))
	if s.list.Changed() {
		if at := s.list.Selected(); at >= 0 && at < len(shown) && shown[at].ID != s.selected {
			s.selected, s.add = shown[at].ID, ""
		}
	}
}

// debuggerDetail is the prototype's adapter detail: the head with the plugin's defaults or the
// user's, the tabs and the stepping tab's patterns and switches.
func (w *window) debuggerDetail(c ui.C, language i18n.Language, adapter SteppingAdapter) {
	s := w.stepping
	b := &w.bp
	draft := w.steppingDraftOf(adapter)
	changed := w.steppingChanged(adapter)
	_, stored := w.effectiveFilters(adapter)
	customized := stored || changed
	plugin := steppingPluginName(adapter)
	ui.Column(c).FillWidth().MinWidth(0).Children(func() {
		ui.Row(c).FillWidth().Gap(12).Items(ui.Start).Children(func() {
			w.pluginTile(c, plugin, 40)
			ui.Column(c).Grow(1).Shrink(1).MinWidth(0).Children(func() {
				ui.Text(c, adapter.Name).FontSize(buildHeading).Weight(gfx.WeightBold).Color(b.text).Ellipsis()
				ui.Row(c).Height(4).Shrink(0)
				ui.Row(c).FillWidth().Gap(6).Items(ui.Center).Children(func() {
					if adapter.PluginName != "" || adapter.PluginID != "" {
						ui.Text(c, i18n.SharedFormat(language, "desktop.buildSettings.providedBy", map[string]string{"plugin": plugin})).
							FontSize(buildSmall).Color(b.sub).Shrink(1).Ellipsis()
						ui.Text(c, "·").FontSize(buildSmall).Color(b.sub).Shrink(0)
					}
					if customized {
						w.tag(c, tagBlue, i18n.Shared(language, "desktop.settings.stepping.customized"))
					} else {
						w.tag(c, tagPlain, i18n.Shared(language, "desktop.settings.stepping.usingDefaults"))
					}
				})
			})
			if customized && w.button(c.Part("restore"), buttonSmall, i18n.Shared(language, "desktop.settings.stepping.restoreDefaults"), s.saving) {
				*draft = draftOf(adapter.Defaults)
				s.saveErr = nil
			}
		})
		ui.Row(c).Height(14).Shrink(0)
		w.tabsBar(c.Part("tabs"), []segment{{value: steppingTab, label: i18n.Shared(language, "desktop.buildSettings.tabStepping")}}, &s.tab)
		ui.Row(c).Height(12).Shrink(0)
		if changed {
			w.box(c.Part("next"), boxNext, func(words gfx.Color) {
				dot(c, 7, b.accent)
				boxText(c, i18n.Shared(language, "desktop.buildSettings.steppingPending"), words)
			})
			ui.Row(c).Height(12).Shrink(0)
		}
		if s.saveErr != nil && s.pending.adapter == adapter.ID {
			message := i18n.SharedFormat(language, "desktop.settings.stepping.saveFailed", map[string]string{"reason": s.saveErr.Error()})
			w.box(c.Part("failed"), boxErr, func(words gfx.Color) {
				boxIcon(c, icons.CircleX, words)
				boxText(c, message, words)
			})
			ui.Row(c).Height(12).Shrink(0)
		}
		w.section(c.Part("patterns"), i18n.Shared(language, "desktop.buildSettings.skipCode"), i18n.Shared(language, "desktop.buildSettings.skipCodeHelp"), nil, func() {
			ui.Row(c).FillWidth().MinWidth(0).PadSides(0, 12, 10, 12).Children(func() {
				w.patternList(c.Part("list"), language, draft)
			})
		})
		ui.Row(c).Height(12).Shrink(0)
		ui.Column(c).FillWidth().MinWidth(0).Shrink(0).Radius(10).Border(1, b.line).Background(b.surface).Pad(6).Children(func() {
			for _, feature := range steppingFeatures(language, draft) {
				k := c.Part(feature.key)
				ui.Row(k).FillWidth().MinHeight(34).PadX(8).PadY(3).Gap(10).Radius(7).Items(ui.Center).
					HitWith(ui.ID(k), feature.label, gfx.HitOptions{Role: gfx.RoleGroup, SkipFocus: true}).
					Hover(ui.Look{}.Background(b.hover)).Children(func() {
					ui.Row(k).Grow(1).Shrink(1).MinWidth(0).Gap(5).Items(ui.Center).Children(func() {
						ui.Text(c, feature.label).FontSize(buildFont).Color(b.text).Shrink(1).Ellipsis()
						w.infoButton(k.Part("help"), feature.help)
					})
					ui.Switch(k.Part("switch"), feature.value, "").Label(feature.label).Disabled(s.saving)
				})
			}
		})
	})
}

// patternList is the prototype's .lst: one row per pattern with its remove button, then the
// field that adds one.
func (w *window) patternList(c ui.C, language i18n.Language, draft *steppingDraft) {
	s := w.stepping
	b := &w.bp
	ui.Column(c).Grow(1).Shrink(1).MinWidth(0).Radius(8).Border(1, b.line).Children(func() {
		if len(draft.patterns) == 0 {
			ui.Row(c).FillWidth().PadX(8).PadY(5).Children(func() {
				ui.Text(c, i18n.Shared(language, "desktop.buildSettings.noPatterns")).FontSize(buildFont).Color(b.faint)
			})
			ui.Row(c).FillWidth().Height(1).Shrink(0).Background(b.line)
		}
		remove := -1
		for index, pattern := range draft.patterns {
			k := c.KeyInt(index)
			ui.Row(k).FillWidth().MinWidth(0).PadX(8).PadY(5).Gap(8).Items(ui.Center).
				HitWith(ui.ID(k), pattern, gfx.HitOptions{Role: gfx.RoleGroup, SkipFocus: true}).
				Hover(ui.Look{}.Background(b.hover)).Children(func() {
				ui.Text(c, pattern).FontSize(buildMono).Mono().Color(b.text).Grow(1).Shrink(1).MinWidth(0).Ellipsis()
				if w.iconButton(k.Part("remove"), icons.X, i18n.Shared(language, "desktop.buildSettings.removePattern"), s.saving) {
					remove = index
				}
			})
			ui.Row(k).FillWidth().Height(1).Shrink(0).Background(b.line)
		}
		if remove >= 0 {
			draft.patterns = slices.Delete(slices.Clone(draft.patterns), remove, remove+1)
		}
		ui.Row(c).FillWidth().MinWidth(0).Pad(6).Gap(6).Items(ui.Center).Children(func() {
			label := i18n.Shared(language, "desktop.buildSettings.addPattern")
			var field ui.Box
			ui.Row(c).Grow(1).Shrink(1).MinWidth(0).Children(func() {
				field = w.filterField(c.Part("field"), &s.add, label, label, false)
			})
			pattern := strings.TrimSpace(s.add)
			add := w.button(c.Part("add"), buttonSmall, i18n.Shared(language, "ai.add"), pattern == "" || s.saving)
			if (add || field.Submitted()) && pattern != "" && !s.saving {
				if !slices.Contains(draft.patterns, pattern) {
					draft.patterns = append(slices.Clone(draft.patterns), pattern)
				}
				s.add = ""
			}
		})
	})
}
