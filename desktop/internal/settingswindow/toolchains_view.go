package settingswindow

import (
	"context"
	"errors"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/configfile"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/toolchain"
	"github.com/vivaui/viva/ui"
)

// toolchainState is the Build settings page's draft. Only the window thread reads or
// writes the fields. A load and a save are two page Effects: a new key cancels the one
// before it, so a result of a replaced request never reaches the draft, and the window
// takes what finished with take at the start of a paint.
type toolchainState struct {
	loader     ToolchainLoader
	loadEffect *ui.EffectState[toolchain.Snapshot, int]
	saveEffect *ui.EffectState[toolchain.Snapshot, int]
	// loadKey and saveKey name the requests; zero means none was made. The save's inputs
	// are written before its key changes and are read by that one run only.
	loadKey, saveKey int
	saveSnapshot     toolchain.Snapshot
	saveEdits        []toolchain.Edit

	loading bool
	saving  bool
	loaded  bool
	saved   bool
	failed  error

	snapshot toolchain.Snapshot
	// draft maps a tool ID to the directory home the user selected, empty for
	// the automatic layers.
	draft map[string]string
	// picks are the radio groups' bound values, one per tool, mirrored from draft in each paint.
	picks map[string]*string
}

func newToolchainState(loader ToolchainLoader) *toolchainState {
	t := &toolchainState{loader: loader, draft: make(map[string]string), picks: make(map[string]*string)}
	if loader != nil {
		t.loadEffect = ui.NewEffect[toolchain.Snapshot, int](func(ctx context.Context) (toolchain.Snapshot, error) {
			return loader.Load(ctx)
		})
		t.saveEffect = ui.NewEffect[toolchain.Snapshot, int](func(ctx context.Context) (toolchain.Snapshot, error) {
			return loader.Save(ctx, t.saveSnapshot, t.saveEdits)
		})
	}
	return t
}

func toolchainFailureMessage(language i18n.Language, err error) string {
	if errors.Is(err, toolchain.ErrPinCommitted) {
		return i18n.Shared(language, "desktop.toolchains.reloadAfterSave")
	}
	if errors.Is(err, toolchain.ErrPinConflict) {
		return i18n.Shared(language, "desktop.toolchains.sourceChanged")
	}
	var rejection *core.MarketplaceRejection
	if errors.Is(err, configfile.ErrTarget) || errors.Is(err, configfile.ErrEncoding) || errors.Is(err, configfile.ErrTooLarge) ||
		(errors.As(err, &rejection) && (rejection.Code == "plugin.toolchain.invalidDocument" || rejection.Code == "plugin.toolchain.invalidIgnore")) {
		return i18n.Shared(language, "desktop.toolchains.sourceInvalid")
	}
	return i18n.SharedFormat(language, "desktop.toolchains.loadFailed", map[string]string{"reason": err.Error()})
}

// beginLoad reads the project's toolchains off the window thread.
func (t *toolchainState) beginLoad() {
	if t.loader == nil || t.loading || t.saving {
		return
	}
	t.loadKey++
	t.loading = true
	t.failed = nil
}

// beginSave writes the draft's changed pins. Every edit goes through the same
// Core-validated document merge; a conflict keeps the draft.
func (t *toolchainState) beginSave() {
	if t.loader == nil || !t.loaded || t.loading || t.saving || !t.hasDraft() {
		return
	}
	edits := t.edits()
	if len(edits) == 0 {
		return
	}
	t.saveSnapshot, t.saveEdits = t.snapshot, edits
	t.saveKey++
	t.saving = true
	t.failed = nil
}

// take applies finished work on the window thread at the start of a paint.
func (t *toolchainState) take() {
	if t.loadEffect == nil {
		return
	}
	if snapshot, err, ok := t.loadEffect.Take(); ok {
		t.finish(snapshot, err, false)
	}
	if snapshot, err, ok := t.saveEffect.Take(); ok {
		t.finish(snapshot, err, true)
	}
}

func (t *toolchainState) finish(snapshot toolchain.Snapshot, err error, saved bool) {
	t.loading, t.saving = false, false
	if err != nil {
		t.failed = err
		if errors.Is(err, toolchain.ErrPinCommitted) {
			t.loaded = false
		}
		t.saved = false
		return
	}
	t.apply(snapshot, saved)
}

// declare keeps the requests that are out alive. The window declares it in every paint, so
// leaving the Build page does not cancel a save that is writing the pins.
func (t *toolchainState) declare(c ui.C) {
	if t.loadEffect == nil {
		return
	}
	if t.loadKey != 0 {
		ui.Effect(c, t.loadEffect, t.loadKey)
	}
	if t.saveKey != 0 {
		ui.Effect(c, t.saveEffect, t.saveKey)
	}
}

func (t *toolchainState) apply(snapshot toolchain.Snapshot, saved bool) {
	t.snapshot = snapshot
	t.loaded = true
	t.saved = saved
	t.failed = nil
	if !saved {
		t.draft = make(map[string]string, len(snapshot.Tools))
		for _, tool := range snapshot.Tools {
			if tool.Pin != nil {
				t.draft[tool.ID] = tool.Pin.Home
			}
		}
	}
}

func (t *toolchainState) choose(tool, home string) {
	if t.snapshot.Tools == nil {
		return
	}
	if t.draft == nil {
		t.draft = make(map[string]string)
	}
	t.draft[tool] = home
	t.saved = false
}

func (t *toolchainState) resetDrafts() {
	for _, tool := range t.snapshot.Tools {
		t.draft[tool.ID] = ""
	}
	t.saved = false
}

func (t *toolchainState) hasDraft() bool {
	for _, tool := range t.snapshot.Tools {
		current := ""
		if tool.Pin != nil {
			current = tool.Pin.Home
		}
		if t.draft[tool.ID] != current {
			return true
		}
	}
	return false
}

// edits builds one pin change per tool whose draft differs from the saved
// document. A tool without an installed version cannot be pinned.
func (t *toolchainState) edits() []toolchain.Edit {
	var edits []toolchain.Edit
	for _, tool := range t.snapshot.Tools {
		current := ""
		if tool.Pin != nil {
			current = tool.Pin.Home
		}
		wanted := t.draft[tool.ID]
		if wanted == current {
			continue
		}
		if wanted == "" {
			edits = append(edits, toolchain.Edit{Tool: tool.ID})
			continue
		}
		for _, installation := range tool.Installations {
			if installation.Home != wanted || installation.Version == "" {
				continue
			}
			edits = append(edits, toolchain.Edit{Tool: tool.ID, Pin: &core.ToolchainPin{
				Home: installation.Home, Version: installation.Version, Provider: installation.Provider,
			}})
			break
		}
	}
	return edits
}

// toolchainsPage is the Build settings page: each enabled plugin's declared
// tools, the effective layer Core selected, and an explicit local pin draft.
func (w *window) toolchainsPage(c ui.C) {
	if w.ctrl.opts.Toolchains == nil {
		w.unavailablePage(c)
		return
	}
	t := w.toolchains
	if !t.loaded && !t.loading && !t.saving && t.failed == nil {
		t.beginLoad()
	}
	language := w.marketLanguage()
	w.pageScroll(c, pageBuild, func() {
		w.card(c, i18n.Shared(language, "desktop.toolchains.title"), i18n.Shared(language, "desktop.toolchains.description"), func() {
			ui.Column(c).FillWidth().Gap(8).Children(func() {
				ui.Wrap(c, i18n.Shared(language, "desktop.toolchains.chooseHelp")).FontSize(12).Color(w.pal.muted)
				ui.Row(c).FillWidth().Gap(8).Items(ui.Center).Children(func() {
					if ui.Button(c, i18n.Shared(language, "desktop.toolchains.reload")).Outline().Clicked() {
						t.beginLoad()
					}
					if ui.Button(c, i18n.Shared(language, "desktop.toolchains.reset")).Outline().Clicked() {
						t.resetDrafts()
					}
					ui.Spacer(c)
					if ui.Button(c, i18n.Shared(language, "desktop.toolchains.save")).Disabled(!t.loaded || !t.hasDraft() || t.saving || t.loading).Clicked() {
						t.beginSave()
					}
				})
				switch {
				case t.loading:
					ui.Text(c, i18n.Shared(language, "desktop.toolchains.loading")).FontSize(12).Color(w.pal.muted)
				case t.saving:
					ui.Text(c, i18n.Shared(language, "desktop.toolchains.saving")).FontSize(12).Color(w.pal.muted)
				case t.failed != nil:
					ui.Text(c, toolchainFailureMessage(language, t.failed)).FontSize(12).Color(w.pal.danger)
				case t.saved:
					ui.Text(c, i18n.Shared(language, "desktop.toolchains.saved")).FontSize(12).Color(w.pal.muted)
				}
			})
		})
		if t.snapshot.Root == "" && t.loaded {
			w.card(c.Part("no-project"), i18n.Shared(language, "desktop.toolchains.title"), "", func() {
				ui.Text(c, i18n.Shared(language, "desktop.toolchains.noProject")).FontSize(12).Color(w.pal.muted)
			})
			return
		}
		for _, conflict := range t.snapshot.Conflicts {
			plugins := strings.Join(conflict.PluginIDs, ", ")
			w.card(c.Key("conflict:"+conflict.Tool), i18n.Shared(language, "desktop.toolchains.title"), "", func() {
				ui.Text(c, i18n.SharedFormat(language, "desktop.toolchains.conflict", map[string]string{"tool": conflict.Tool, "plugins": plugins})).FontSize(12).Color(w.pal.danger)
			})
		}
		for _, tool := range t.snapshot.Tools {
			w.card(c.Key("tool:"+tool.ID), tool.DisplayName, "", func() {
				w.toolchainTool(c, language, tool)
			})
		}
	})
}

func (w *window) toolchainTool(c ui.C, language i18n.Language, tool toolchain.Tool) {
	t := w.toolchains
	ui.Column(c).FillWidth().Gap(6).Children(func() {
		ui.Text(c, tool.PluginID).FontSize(11).Color(w.pal.muted)
		switch {
		case tool.Effective != nil:
			value := tool.Effective.Executable
			if tool.Effective.Version != "" {
				value += " (" + tool.Effective.Version + ")"
			}
			if tool.Effective.Layer != "" {
				value += " · " + tool.Effective.Layer
			}
			ui.Text(c, i18n.SharedFormat(language, "desktop.toolchains.effective", map[string]string{"value": value})).FontSize(12).Color(w.pal.text)
		default:
			reason := toolchainReason(tool)
			ui.Text(c, i18n.SharedFormat(language, "desktop.toolchains.unavailable", map[string]string{"reason": reason})).FontSize(12).Color(w.pal.danger)
		}
		pick := t.pick(tool.ID)
		*pick = t.draft[tool.ID]
		automatic := ""
		if tool.AutomaticHome != "" {
			automatic = tool.AutomaticHome
		} else {
			automatic = i18n.Shared(language, "desktop.toolchains.noInstallations")
		}
		w.radio(c.Part("automatic"), pick, "", i18n.SharedFormat(language, "desktop.toolchains.automatic", map[string]string{"value": automatic}), false)
		pinShown := false
		for _, installation := range tool.Installations {
			home := installation.Home
			if tool.Pin != nil && tool.Pin.Home == home {
				pinShown = true
			}
			label := i18n.SharedFormat(language, "desktop.toolchains.installation", map[string]string{
				"home": home, "version": installation.Version, "provider": installation.Provider,
			})
			w.radio(c.Key(home), pick, home, label, installation.Version == "")
		}
		if tool.Pin != nil && !pinShown {
			label := i18n.SharedFormat(language, "desktop.toolchains.pinSource", map[string]string{"directory": tool.PinSource})
			w.radio(c.Part("pin"), pick, tool.Pin.Home, tool.Pin.Home+" · "+label, false)
		}
		if *pick != t.draft[tool.ID] {
			t.choose(tool.ID, *pick)
		}
		for _, shell := range tool.Shell {
			version := shell.Variable
			if shell.Version != nil {
				version += " " + *shell.Version
			} else if shell.Reason != "" {
				version += " " + shell.Reason
			}
			ui.Text(c, i18n.SharedFormat(language, "desktop.toolchains.installation", map[string]string{
				"home": shell.Home, "version": version, "provider": shell.Variable,
			})).FontSize(11).Color(w.pal.muted)
		}
		if tool.ProviderQueriesUnsupported {
			ui.Text(c, i18n.Shared(language, "desktop.toolchains.providerUnsupported")).FontSize(11).Color(w.pal.muted)
		}
	})
}

func toolchainReason(tool toolchain.Tool) string {
	for _, trace := range tool.Trace {
		if trace.Reason != nil && trace.Reason.Code != "" {
			return trace.Reason.Code
		}
	}
	return "notFound"
}

// pick is the bound value of one tool's radio group. It lives as long as the window, so the
// radios keep their identities.
func (t *toolchainState) pick(tool string) *string {
	if t.picks[tool] == nil {
		t.picks[tool] = new(string)
	}
	return t.picks[tool]
}
