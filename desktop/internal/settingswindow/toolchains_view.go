package settingswindow

import (
	"context"
	"errors"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/toolchain"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

var (
	toolchainReloadID = tree.ID(root, "toolchain-reload")
	toolchainResetID  = tree.ID(root, "toolchain-reset")
	toolchainSaveID   = tree.ID(root, "toolchain-save")
	toolchainChoice   = tree.Sub(root, tree.Name("toolchain-choice"))
)

// toolchainResult is one background load or save, tagged with the generation it
// belongs to so a closed or replaced page cannot publish it.
type toolchainResult struct {
	generation uint64
	snapshot   toolchain.Snapshot
	err        error
	saved      bool
}

// toolchainState is the Build settings page's draft. Only the window thread
// reads or writes the fields; a worker owns only its request and the result
// channel.
type toolchainState struct {
	loader  ToolchainLoader
	wake    func()
	results chan toolchainResult
	cancel  context.CancelFunc

	generation uint64
	loading    bool
	saving     bool
	loaded     bool
	saved      bool
	failed     error

	snapshot toolchain.Snapshot
	// draft maps a tool ID to the directory home the user selected, empty for
	// the automatic layers.
	draft map[string]string
}

func newToolchainState(loader ToolchainLoader, wake func()) toolchainState {
	return toolchainState{loader: loader, wake: wake, results: make(chan toolchainResult, 2), draft: make(map[string]string)}
}

func toolchainFailureMessage(language i18n.Language, err error) string {
	if errors.Is(err, toolchain.ErrPinConflict) {
		return i18n.Shared(language, "desktop.toolchains.sourceChanged")
	}
	return i18n.SharedFormat(language, "desktop.toolchains.loadFailed", map[string]string{"reason": err.Error()})
}

// beginLoad reads the project's toolchains off the window thread.
func (t *toolchainState) beginLoad() {
	if t.loader == nil || t.loading || t.saving {
		return
	}
	t.generation++
	generation := t.generation
	t.loading = true
	t.failed = nil
	loader := t.loader
	wake := t.wake
	ctx, cancel := context.WithCancel(context.Background())
	t.cancel = cancel
	go func() {
		snapshot, err := loader.Load(ctx)
		t.publish(toolchainResult{generation: generation, snapshot: snapshot, err: err})
		if wake != nil {
			wake()
		}
	}()
}

// beginSave writes the draft's changed pins. Every edit goes through the same
// Core-validated document merge; a conflict keeps the draft.
func (t *toolchainState) beginSave() {
	if t.loader == nil || t.loading || t.saving || !t.hasDraft() {
		return
	}
	edits := t.edits()
	if len(edits) == 0 {
		return
	}
	t.generation++
	generation := t.generation
	t.saving = true
	t.failed = nil
	loader := t.loader
	snapshot := t.snapshot
	wake := t.wake
	ctx, cancel := context.WithCancel(context.Background())
	t.cancel = cancel
	go func() {
		updated, err := loader.Save(ctx, snapshot, edits)
		t.publish(toolchainResult{generation: generation, snapshot: updated, err: err, saved: true})
		if wake != nil {
			wake()
		}
	}()
}

// publish never blocks: a window that closed its page drops the result instead
// of leaving a goroutine waiting for a reader that will never come.
func (t *toolchainState) publish(result toolchainResult) {
	select {
	case t.results <- result:
	default:
	}
}

// drain applies finished work on the window thread. It is called at each paint.
func (t *toolchainState) drain() {
	for {
		select {
		case result := <-t.results:
			if result.generation != t.generation {
				continue
			}
			t.loading, t.saving = false, false
			if result.err != nil {
				t.failed = result.err
				t.saved = false
				continue
			}
			t.apply(result.snapshot, result.saved)
		default:
			return
		}
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

func (t *toolchainState) close() {
	t.generation++
	if t.cancel != nil {
		t.cancel()
		t.cancel = nil
	}
	t.loading, t.saving = false, false
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

// drawToolchains is the Build settings page: each enabled plugin's declared
// tools, the effective layer Core selected, and an explicit local pin draft.
func (w *window) drawToolchains(f *ui.Frame) {
	if w.ctrl.opts.Toolchains == nil {
		w.drawUnavailable(f)
		return
	}
	t := &w.toolchains
	if !t.loaded && !t.loading && !t.saving && t.failed == nil {
		t.beginLoad()
	}
	language := w.marketLanguage()
	scroll := pageScrollScope.At(int(pageBuild))
	f.ScrollArea(scroll).Grow(1).Shrink(1).MinHeight(0).PadSides(18, contentPad, contentPad, contentPad).Gap(cardGap).Children(func() {
		w.card(f, 20, i18n.Shared(language, "desktop.toolchains.title"), i18n.Shared(language, "desktop.toolchains.description"), func() {
			f.Column().FillWidth().Gap(8).Children(func() {
				f.Wrap(i18n.Shared(language, "desktop.toolchains.chooseHelp")).FontSize(12).Color(w.pal.muted)
				f.Row().FillWidth().Gap(8).Items(ui.Center).Children(func() {
					if f.Button(toolchainReloadID, i18n.Shared(language, "desktop.toolchains.reload")).Outline().Clicked() {
						t.beginLoad()
					}
					if f.Button(toolchainResetID, i18n.Shared(language, "desktop.toolchains.reset")).Outline().Clicked() {
						t.resetDrafts()
					}
					f.Spacer()
					if f.Button(toolchainSaveID, i18n.Shared(language, "desktop.toolchains.save")).Disabled(!t.hasDraft() || t.saving || t.loading).Clicked() {
						t.beginSave()
					}
				})
				switch {
				case t.loading:
					f.Text(i18n.Shared(language, "desktop.toolchains.loading")).FontSize(12).Color(w.pal.muted)
				case t.saving:
					f.Text(i18n.Shared(language, "desktop.toolchains.saving")).FontSize(12).Color(w.pal.muted)
				case t.failed != nil:
					f.Text(toolchainFailureMessage(language, t.failed)).FontSize(12).Color(w.pal.danger)
				case t.saved:
					f.Text(i18n.Shared(language, "desktop.toolchains.saved")).FontSize(12).Color(w.pal.muted)
				}
			})
		})
		if t.snapshot.Root == "" && t.loaded {
			w.card(f, 21, i18n.Shared(language, "desktop.toolchains.title"), "", func() {
				f.Text(i18n.Shared(language, "desktop.toolchains.noProject")).FontSize(12).Color(w.pal.muted)
			})
			return
		}
		for _, conflict := range t.snapshot.Conflicts {
			plugins := strings.Join(conflict.PluginIDs, ", ")
			w.card(f, 22, i18n.Shared(language, "desktop.toolchains.title"), "", func() {
				f.Text(i18n.SharedFormat(language, "desktop.toolchains.conflict", map[string]string{"tool": conflict.Tool, "plugins": plugins})).FontSize(12).Color(w.pal.danger)
			})
		}
		for index, tool := range t.snapshot.Tools {
			index, tool := index, tool
			w.card(f, 30+index, tool.DisplayName, "", func() {
				w.drawToolchainTool(f, language, index, tool)
			})
		}
	})
}

func (w *window) drawToolchainTool(f *ui.Frame, language i18n.Language, index int, tool toolchain.Tool) {
	t := &w.toolchains
	f.Column().FillWidth().Gap(6).Children(func() {
		f.Text(tool.PluginID).FontSize(11).Color(w.pal.muted)
		switch {
		case tool.Effective != nil:
			value := tool.Effective.Executable
			if tool.Effective.Version != "" {
				value += " (" + tool.Effective.Version + ")"
			}
			if tool.Effective.Layer != "" {
				value += " · " + tool.Effective.Layer
			}
			f.Text(i18n.SharedFormat(language, "desktop.toolchains.effective", map[string]string{"value": value})).FontSize(12).Color(w.pal.text)
		default:
			reason := toolchainReason(tool)
			f.Text(i18n.SharedFormat(language, "desktop.toolchains.unavailable", map[string]string{"reason": reason})).FontSize(12).Color(w.pal.danger)
		}
		selected := t.draft[tool.ID]
		automatic := ""
		if tool.AutomaticHome != "" {
			automatic = tool.AutomaticHome
		} else {
			automatic = i18n.Shared(language, "desktop.toolchains.noInstallations")
		}
		if w.toolchainRadio(f, toolchainChoice.At(index*1000), i18n.SharedFormat(language, "desktop.toolchains.automatic", map[string]string{"value": automatic}), selected == "", false) {
			t.choose(tool.ID, "")
		}
		pinShown := false
		for option, installation := range tool.Installations {
			home := installation.Home
			if tool.Pin != nil && tool.Pin.Home == home {
				pinShown = true
			}
			label := i18n.SharedFormat(language, "desktop.toolchains.installation", map[string]string{
				"home": home, "version": installation.Version, "provider": installation.Provider,
			})
			if w.toolchainRadio(f, toolchainChoice.At(index*1000+1+option), label, selected == home, installation.Version == "") {
				t.choose(tool.ID, home)
			}
		}
		if tool.Pin != nil && !pinShown {
			label := i18n.SharedFormat(language, "desktop.toolchains.pinSource", map[string]string{"directory": tool.PinSource})
			if w.toolchainRadio(f, toolchainChoice.At(index*1000+900), tool.Pin.Home+" · "+label, selected == tool.Pin.Home, false) {
				t.choose(tool.ID, tool.Pin.Home)
			}
		}
		for _, shell := range tool.Shell {
			version := shell.Variable
			if shell.Version != nil {
				version += " " + *shell.Version
			} else if shell.Reason != "" {
				version += " " + shell.Reason
			}
			f.Text(i18n.SharedFormat(language, "desktop.toolchains.installation", map[string]string{
				"home": shell.Home, "version": version, "provider": shell.Variable,
			})).FontSize(11).Color(w.pal.muted)
		}
		if tool.ProviderQueriesUnsupported {
			f.Text(i18n.Shared(language, "desktop.toolchains.providerUnsupported")).FontSize(11).Color(w.pal.muted)
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

// toolchainRadio is the settings window's radio row: a ring that fills with the
// accent color and a center dot when selected.
func (w *window) toolchainRadio(f *ui.Frame, id gfx.ID, title string, selected, disabled bool) bool {
	ring := w.pal.subtle
	if selected {
		ring = w.pal.accent
	}
	row := f.Row().Gap(7).Items(ui.Center).HitWith(id, title, gfx.HitOptions{Role: gfx.RoleRadio, Checked: selected, Disabled: disabled})
	if disabled {
		row = row.Opacity(0.45)
	}
	row.Children(func() {
		f.Row().Size(15, 15).Shrink(0).Center().Children(func() {
			f.Row().Size(13, 13).Radius(6.5).Background(w.pal.card).Border(1.2, ring).Center().Children(func() {
				if selected {
					f.Row().Size(7, 7).Radius(3.5).Background(ring)
				}
			})
		})
		f.Text(title).FontSize(12).Color(w.pal.text).Ellipsis()
	})
	return !disabled && row.Clicked()
}
