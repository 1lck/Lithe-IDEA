package settingswindow

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/configfile"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/toolchain"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/ui"
)

// toolchainState is the Build settings page's draft. Only the window thread reads or
// writes the fields. A load and a save are two page Effects: a new key cancels the one
// before it, so a result of a replaced request never reaches the draft, and the window
// takes what finished with take at the start of a paint.
type toolchainState struct {
	loader                   ToolchainLoader
	loadEffect               *ui.EffectState[toolchain.Snapshot, int]
	saveEffect               *ui.EffectState[toolchain.Snapshot, int]
	inspectEffect            *ui.EffectState[core.ToolchainSelection, int]
	inspectKey               int
	inspectSnapshot          toolchain.Snapshot
	inspectTool, inspectHome string
	inspecting               bool
	inputs                   map[string]*string
	custom                   map[string]core.ToolchainPin
	scope, loadScope         string
	registrations            map[string]bool
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
	// picks are the lists' bound values, one per tool, mirrored from draft in each paint.
	picks map[string]*string
	// customizing names the tools whose list is on Custom…: their directory field shows
	// until a directory checks out or another entry is chosen.
	customizing map[string]bool
}

// toolchainCustom is the value of the entry of a tool's list that asks for a directory the
// discovery did not find. A home is a path, which never holds a NUL, so it names none.
const toolchainCustom = "\x00custom"

func newToolchainState(loader ToolchainLoader) *toolchainState {
	t := &toolchainState{loader: loader, scope: "project", draft: make(map[string]string), picks: make(map[string]*string), customizing: make(map[string]bool), inputs: make(map[string]*string), custom: make(map[string]core.ToolchainPin), registrations: make(map[string]bool)}
	if _, ok := loader.(ToolchainScopedLoader); ok {
		t.scope = "global"
	}
	if loader != nil {
		t.loadEffect = ui.NewEffect[toolchain.Snapshot, int](func(ctx context.Context) (toolchain.Snapshot, error) {
			if scoped, ok := loader.(ToolchainScopedLoader); ok {
				return scoped.LoadScope(ctx, t.loadScope)
			}
			return loader.Load(ctx)
		})
		t.saveEffect = ui.NewEffect[toolchain.Snapshot, int](func(ctx context.Context) (toolchain.Snapshot, error) {
			return loader.Save(ctx, t.saveSnapshot, t.saveEdits)
		})
	}
	if inspector, ok := loader.(ToolchainInspector); ok {
		t.inspectEffect = ui.NewEffect[core.ToolchainSelection, int](func(ctx context.Context) (core.ToolchainSelection, error) {
			ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
			defer cancel()
			return inspector.Inspect(ctx, t.inspectSnapshot, t.inspectTool, t.inspectHome)
		})
	}
	return t
}

func (t *toolchainState) beginInspect(tool, home string) {
	if t.inspectEffect == nil || t.loading || t.saving || t.inspecting || !t.loaded || home == "" {
		return
	}
	t.inspectSnapshot, t.inspectTool, t.inspectHome = t.snapshot, tool, home
	t.inspectKey++
	t.inspecting, t.saved, t.failed = true, false, nil
}

func toolchainFailureMessage(language i18n.Language, err error) string {
	var unavailable *toolchain.UnavailableError
	if errors.As(err, &unavailable) {
		return i18n.Shared(language, "desktop.toolchains.invalidDirectory")
	}
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
	if t.loader == nil || t.loading || t.saving || t.inspecting {
		return
	}
	t.loadScope = t.scope
	t.loadKey++
	t.loading = true
	t.failed = nil
}

// beginSave writes the draft's changed pins. Every edit goes through the same
// Core-validated document merge; a conflict keeps the draft.
func (t *toolchainState) beginSave() {
	if t.loader == nil || !t.loaded || t.loading || t.saving || t.inspecting || !t.hasDraft() {
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
	if t.inspectEffect != nil {
		if selection, err, ok := t.inspectEffect.Take(); ok {
			t.inspecting, t.failed = false, err
			if err == nil && selection.Home != nil {
				t.acceptInspection(t.inspectTool, selection)
			}
		}
	}
}

func (t *toolchainState) acceptInspection(id string, selection core.ToolchainSelection) {
	if selection.Home == nil {
		return
	}
	pin := core.ToolchainPin{Home: *selection.Home, Version: selection.Version, Provider: "host:manual"}
	if t.snapshot.Global {
		for index := range t.snapshot.Tools {
			tool := &t.snapshot.Tools[index]
			if tool.ID != id {
				continue
			}
			registered, installed := false, false
			for _, home := range tool.CustomHomes {
				registered = registered || home == pin.Home
			}
			if !registered {
				tool.CustomHomes = append(tool.CustomHomes, pin.Home)
				t.registrations[id] = true
			}
			for _, installation := range tool.Installations {
				installed = installed || installation.Home == pin.Home
			}
			if !installed {
				tool.Installations = append(tool.Installations, core.ToolchainInstallation{Home: pin.Home, Version: pin.Version, Provider: pin.Provider})
			}
		}
	} else {
		t.custom[id] = pin
	}
	// The checked directory is now an entry of the list, which shows it chosen.
	delete(t.customizing, id)
	t.choose(id, pin.Home)
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
	if t.inspectKey != 0 {
		ui.Effect(c, t.inspectEffect, t.inspectKey)
	}
}

func (t *toolchainState) apply(snapshot toolchain.Snapshot, saved bool) {
	t.snapshot = snapshot
	t.loaded = true
	t.saved = saved
	t.failed = nil
	{
		t.custom = make(map[string]core.ToolchainPin)
		t.registrations = make(map[string]bool)
		t.customizing = make(map[string]bool)
		t.inputs = make(map[string]*string)
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
	clear(t.customizing)
	t.saved = false
}

func (t *toolchainState) hasDraft() bool {
	if len(t.registrations) != 0 {
		return true
	}
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
		if wanted == current && !t.registrations[tool.ID] {
			continue
		}
		if wanted == "" {
			edits = append(edits, toolchain.Edit{Tool: tool.ID})
			continue
		}
		if pin, ok := t.custom[tool.ID]; ok && pin.Home == wanted {
			edits = append(edits, toolchain.Edit{Tool: tool.ID, Pin: &pin})
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
	if w.ctrl.opts.Toolchains == nil && !w.stepping.available() {
		w.unavailablePage(c)
		return
	}
	language := w.marketLanguage()
	w.pageScroll(c, pageBuild, func() {
		if w.ctrl.opts.Toolchains != nil {
			w.toolchainCards(c, language)
		}
		w.steppingCard(c, language)
	})
}

// toolchainCards are the Build page's cards of the tools the installed plugins resolve.
func (w *window) toolchainCards(c ui.C, language i18n.Language) {
	t := w.toolchains
	if !t.loaded && !t.loading && !t.saving && t.failed == nil {
		t.beginLoad()
	}
	w.card(c, i18n.Shared(language, "desktop.toolchains.title"), i18n.Shared(language, "desktop.toolchains.description"), func() {
		ui.Column(c).FillWidth().Gap(8).Children(func() {
			if _, ok := t.loader.(ToolchainScopedLoader); ok {
				previous := t.scope
				ui.Row(c.Part("scope")).FillWidth().Gap(16).Children(func() {
					disabled := t.loading || t.saving || t.inspecting || t.hasDraft()
					w.radio(c.Part("global"), &t.scope, "global", i18n.Shared(language, "desktop.toolchains.global"), disabled)
					w.radio(c.Part("project"), &t.scope, "project", i18n.Shared(language, "desktop.toolchains.project"), disabled)
				})
				if t.scope != previous {
					t.beginLoad()
				}
			}
			help := i18n.Shared(language, "desktop.toolchains.chooseHelp")
			if t.scope == "global" {
				help = i18n.Shared(language, "desktop.toolchains.globalHelp")
			}
			ui.Wrap(c, help).FontSize(12).Color(w.pal.muted)
			ui.Row(c).FillWidth().Gap(8).Items(ui.Center).Children(func() {
				if ui.Button(c, i18n.Shared(language, "desktop.toolchains.reload")).Outline().Disabled(t.loading || t.saving || t.inspecting).Clicked() {
					t.beginLoad()
				}
				if ui.Button(c, i18n.Shared(language, "desktop.toolchains.reset")).Outline().Disabled(t.loading || t.saving || t.inspecting).Clicked() {
					t.resetDrafts()
				}
				ui.Spacer(c)
				if ui.Button(c, i18n.Shared(language, "desktop.toolchains.save")).Disabled(!t.loaded || !t.hasDraft() || t.saving || t.loading || t.inspecting).Clicked() {
					t.beginSave()
				}
			})
			switch {
			case t.loading || t.inspecting:
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
	if t.snapshot.Root == "" && !t.snapshot.Global && t.loaded {
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
}

func (w *window) toolchainTool(c ui.C, language i18n.Language, tool toolchain.Tool) {
	t := w.toolchains
	busy := t.loading || t.saving || t.inspecting
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
		// One list holds every directory the tool can use: the automatic choice, which shows
		// what discovery picks, each installation found, the saved pin, a checked directory,
		// and, where directories can be checked, Custom… for one discovery did not find.
		var choices []string
		labels := make(map[string]string)
		add := func(home, label string) {
			if _, ok := labels[home]; !ok {
				choices = append(choices, home)
				labels[home] = label
			}
		}
		automatic := tool.AutomaticHome
		if automatic == "" {
			automatic = i18n.Shared(language, "desktop.toolchains.noInstallations")
		}
		add("", i18n.SharedFormat(language, "desktop.toolchains.automatic", map[string]string{"value": automatic}))
		// An installation without a version cannot be pinned, so it is not a choice; it is
		// listed under the list.
		var unversioned []string
		for _, installation := range tool.Installations {
			label := i18n.SharedFormat(language, "desktop.toolchains.installation", map[string]string{
				"home": installation.Home, "version": installation.Version, "provider": installation.Provider,
			})
			if installation.Version == "" {
				unversioned = append(unversioned, label)
				continue
			}
			add(installation.Home, label)
		}
		if tool.Pin != nil {
			label := i18n.SharedFormat(language, "desktop.toolchains.pinSource", map[string]string{"directory": tool.PinSource})
			add(tool.Pin.Home, tool.Pin.Home+" · "+label)
		}
		if pin, ok := t.custom[tool.ID]; ok {
			add(pin.Home, i18n.SharedFormat(language, "desktop.toolchains.installation", map[string]string{"home": pin.Home, "version": pin.Version, "provider": pin.Provider}))
		}
		if t.inspectEffect != nil {
			add(toolchainCustom, i18n.Shared(language, "desktop.toolchains.custom"))
		}
		pick := t.pick(tool.ID)
		*pick = t.draft[tool.ID]
		if t.customizing[tool.ID] {
			*pick = toolchainCustom
		}
		// A draft of a directory no entry names still shows as itself.
		add(*pick, *pick)
		label := func(home string) string { return labels[home] }
		if busy {
			w.readOnlyField(c.Part("choice"), tool.DisplayName, label(*pick))
		} else {
			ui.Select(c.Part("choice"), pick, choices, label).FillWidth().MinWidth(0).Label(tool.DisplayName)
		}
		if *pick == toolchainCustom {
			t.customizing[tool.ID] = true
		} else {
			delete(t.customizing, tool.ID)
			if *pick != t.draft[tool.ID] {
				t.choose(tool.ID, *pick)
			}
		}
		for _, line := range unversioned {
			ui.Text(c, line).FontSize(11).Color(w.pal.muted)
		}
		if t.customizing[tool.ID] {
			input := t.inputs[tool.ID]
			if input == nil {
				input = new(string)
				t.inputs[tool.ID] = input
			}
			label := i18n.Shared(language, "desktop.toolchains.directory")
			ui.Row(c.Part("manual")).FillWidth().Gap(8).Items(ui.Center).Children(func() {
				if busy {
					w.readOnlyField(c, label, *input)
				} else {
					ui.TextField(c, input, label, label).Grow(1).MinWidth(0).Height(30)
				}
				w.infoButton(c, i18n.Shared(language, "desktop.toolchains.directoryHelp"))
				if ui.Button(c, i18n.Shared(language, "desktop.pluginSettings.browse")).Outline().Disabled(busy).Clicked() {
					c.After(func() { w.pickToolchainDirectory(tool.ID, input, label) })
				}
				if ui.Button(c, i18n.Shared(language, "desktop.toolchains.useDirectory")).Outline().Disabled(busy || *input == "").Clicked() {
					t.beginInspect(tool.ID, *input)
				}
			})
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

func (w *window) pickToolchainDirectory(tool string, input *string, title string) {
	path, err := app.OpenDirectory(app.OpenDirectoryOptions{Title: title})
	// log-exempt: 用户取消：关闭目录选择器不修改工具链草稿。
	if errors.Is(err, app.ErrCanceled) {
		return
	}
	if err != nil {
		w.toolchains.failed = err
		if w.ctrl.opts.MarketplaceError != nil {
			w.ctrl.opts.MarketplaceError(err)
		}
		return
	}
	if path != "" && w.toolchains.inputs[tool] == input {
		*input = path
		w.toolchains.beginInspect(tool, path)
	}
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
