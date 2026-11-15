package settingswindow

import (
	"context"
	"encoding/json"
	"errors"
	"slices"
	"sync"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/configfile"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginsettings"
	"github.com/vivaui/viva/ui"
)

// A control owns its draft. Core supplies input/reset projections; the text is sent
// back unparsed on explicit Save. The controls write into these values where they are
// declared, and a draft stays here when the user leaves the page.
type pluginSettingControl struct {
	// text is the draft of a text, number or path row.
	text  string
	input core.PluginSettingInput
	// options are the indexes of an enumeration's options, the values of its select.
	options []int
	reset   bool
}

func (c *pluginSettingControl) apply(input core.PluginSettingInput) {
	c.input = input
	c.input.Checks = append([]bool(nil), input.Checks...)
	c.text = input.Text
	c.reset = false
}

// pluginSettingsResult is what one save or action finished with.
type pluginSettingsResult struct {
	save   pluginsettings.SaveResult
	saved  bool
	action *pluginservice.SettingsActionResult
	err    error
}

// pluginSettingLayout names one row of the Core-ordered form: a section title, a setting
// or an action.
type pluginSettingLayout struct {
	title  string
	row    int
	action bool
}

// pluginSettingsOp is what the next save or action works from. It is written on the
// window thread before the operation's key changes and read by that run alone.
type pluginSettingsOp struct {
	editor    pluginservice.SettingsEditor
	scope     string
	edits     []core.PluginSettingEdit
	action    string
	confirmed bool
	isAction  bool
}

type pluginSettingsForm struct {
	pageKey            string
	stale              bool
	staleReported      bool
	acting             bool
	actionComplete     bool
	actionCanceled     bool
	actionConfirmation *core.PluginSettingsActionPlan
	// confirmOpen is the bound value of the confirmation dialog.
	confirmOpen       bool
	actionUnavailable string
	layout            []pluginSettingLayout
	report            func(error)
	loader            PluginSettingsLoader
	// loadEffect reads the editor and opEffect saves or runs an action. A new key cancels
	// the run before it, and a result that arrives after that is dropped, so a replaced
	// or closed form can never restore an old editor. Zero keys mean nothing was asked.
	// A cancelled run may still be returning when the next one starts: the loader must
	// honor its context.
	loadEffect     *ui.EffectState[pluginservice.SettingsEditor, int]
	opEffect       *ui.EffectState[pluginSettingsResult, int]
	loadKey, opKey int
	// mu guards what a run reads when it starts, loadID, loadLanguage and op, and the
	// cancel of the operation running: a run may start after the window thread asked for
	// the next one.
	mu           sync.Mutex
	loadID       string
	loadLanguage i18n.Language
	op           pluginSettingsOp
	cancelOp     context.CancelFunc
	running      bool
	id           string
	loaded       bool
	failed       error
	saved        bool
	// language is the interface language the window shows; shown is the one the loaded
	// editor's plugin text was translated for. They differ after a language change until
	// the form is clean and idle and reloads.
	language, shown i18n.Language
	// scope and both drafts are view state; switching scope does not lose edits.
	scope    int
	editor   pluginservice.SettingsEditor
	controls [2][]pluginSettingControl
	// rows is the form's list of rows, which declares only the ones on screen.
	rows ui.ListState
}

func newPluginSettingsForm(loader PluginSettingsLoader) *pluginSettingsForm {
	p := &pluginSettingsForm{loader: loader}
	if loader != nil {
		p.loadEffect = ui.NewEffect[pluginservice.SettingsEditor, int](func(ctx context.Context) (pluginservice.SettingsEditor, error) {
			ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
			defer cancel()
			p.mu.Lock()
			id, language := p.loadID, p.loadLanguage
			p.mu.Unlock()
			return loader.Load(ctx, id, language)
		})
		p.opEffect = ui.NewEffect[pluginSettingsResult, int](p.runOp)
	}
	p.rows.Key = nil
	return p
}

// runOp is the save or the action. The stop button cancels its context through
// cancelOp.
func (p *pluginSettingsForm) runOp(parent context.Context) (pluginSettingsResult, error) {
	ctx, cancel := context.WithTimeout(parent, 30*time.Second)
	p.mu.Lock()
	op := p.op
	p.cancelOp = cancel
	p.mu.Unlock()
	defer func() {
		p.mu.Lock()
		p.cancelOp = nil
		p.mu.Unlock()
		cancel()
	}()
	if op.isAction {
		actions, ok := p.loader.(PluginSettingsActionLoader)
		if !ok {
			return pluginSettingsResult{}, nil
		}
		result, err := actions.Action(ctx, op.editor, op.action, op.confirmed)
		return pluginSettingsResult{action: &result, err: err}, nil
	}
	result, err := p.loader.Save(ctx, op.editor, op.scope, op.edits)
	return pluginSettingsResult{save: result, saved: true, err: err}, nil
}

// stop cancels the running action, as the stop button does.
func (p *pluginSettingsForm) stop() {
	p.mu.Lock()
	cancel := p.cancelOp
	p.mu.Unlock()
	if cancel != nil {
		cancel()
	}
}

func (p *pluginSettingsForm) load(id string) {
	p.stale = false
	p.staleReported = false
	p.actionConfirmation = nil
	p.confirmOpen = false
	p.actionComplete = false
	p.actionCanceled = false
	p.actionUnavailable = ""
	p.acting = false
	if p.loader == nil {
		return
	}
	p.mu.Lock()
	p.loadID, p.loadLanguage = id, p.language
	p.mu.Unlock()
	p.id, p.loaded, p.failed, p.saved = id, false, nil, false
	p.running = true
	p.controls = [2][]pluginSettingControl{}
	p.loadKey++
}

// take applies what finished on the window thread at the start of a paint.
func (p *pluginSettingsForm) take() {
	if p.loadEffect == nil {
		return
	}
	if editor, err, ok := p.loadEffect.Take(); ok {
		p.running = false
		p.applyLoad(editor, err)
	}
	if result, _, ok := p.opEffect.Take(); ok {
		p.running = false
		p.applyOp(result)
	}
}

// declare keeps the form's requests alive. The window declares every form it holds in
// each paint, so leaving a plugin does not cancel its save.
func (p *pluginSettingsForm) declare(c ui.C) {
	if p.loadEffect == nil {
		return
	}
	if p.loadKey != 0 {
		ui.Effect(c, p.loadEffect, p.loadKey)
	}
	if p.opKey != 0 {
		ui.Effect(c, p.opEffect, p.opKey)
	}
}

func (p *pluginSettingsForm) applyOp(result pluginSettingsResult) {
	if result.action != nil {
		p.acting = false
		p.failed = result.err
		p.actionComplete = result.action.Completed
		p.actionCanceled = errors.Is(result.err, context.Canceled)
		if p.actionCanceled {
			p.failed = nil
		}
		plan := result.action.Plan
		if result.err == nil && plan.Kind == "confirmationRequired" {
			// The plan carries the manifest's title; the dialog names the action the way
			// its button does, in the editor's translation. No reload replaces the editor
			// while an action runs, so it is the one the action was planned from.
			for _, action := range p.editor.Snapshot.State.Actions {
				if action.ID == plan.ActionID {
					plan.Title = action.Title
					break
				}
			}
			p.actionConfirmation = &plan
			p.confirmOpen = true
		}
		if result.err == nil && plan.Kind == "unavailable" {
			p.actionUnavailable = plan.Reason
		}
		if p.stale {
			p.sourceChanged()
		}
		return
	}
	p.failed, p.saved = result.err, false
	if result.saved {
		if result.save.Readback != nil {
			p.editor.Snapshot = *result.save.Readback
			p.applyScope(0)
			p.applyScope(1)
			p.saved = result.err == nil
			if p.stale {
				p.sourceChanged()
			}
		}
		// A committed publication without readback invalidates the baseline. Keep
		// drafts visible, but force Reload before another attempt can publish.
		if result.save.Committed && result.save.Readback == nil {
			p.loaded = false
		}
	}
}

func (p *pluginSettingsForm) applyLoad(editor pluginservice.SettingsEditor, err error) {
	p.failed, p.saved = err, false
	if err != nil {
		return
	}
	// Only the window thread writes loadLanguage, and a result of an earlier load is
	// dropped before it gets here, so this is the language the editor was read in.
	p.editor, p.loaded, p.shown = editor, true, p.loadLanguage
	p.applyScope(0)
	p.applyScope(1)
	p.layoutRows()
	if p.stale {
		p.sourceChanged()
	}
}

func (p *pluginSettingsForm) layoutRows() {
	p.layout = nil
	state := &p.editor.Snapshot.State
	sections := state.Sections
	if p.pageKey != "" {
		sections = nil
		for _, page := range state.Pages {
			if page.Key == p.pageKey {
				sections = page.Sections
				break
			}
		}
	}
	for _, section := range sections {
		if section.Title != "" {
			p.layout = append(p.layout, pluginSettingLayout{title: section.Title, row: -1})
		}
		for _, index := range section.Rows {
			p.layout = append(p.layout, pluginSettingLayout{row: index})
		}
		for _, index := range section.Actions {
			p.layout = append(p.layout, pluginSettingLayout{row: index, action: true})
		}
	}
}

func (p *pluginSettingsForm) applyScope(scope int) {
	editors := p.editor.Snapshot.State.Editors.Global
	if scope == 1 {
		editors = p.editor.Snapshot.State.Editors.Project
	}
	p.controls[scope] = make([]pluginSettingControl, len(editors))
	for index, editor := range editors {
		control := &p.controls[scope][index]
		control.apply(editor.Input)
		if declaration := &p.editor.Snapshot.State.Rows[index].Declaration; declaration.Kind == "enum" {
			control.options = make([]int, len(declaration.Options))
			for option := range control.options {
				control.options[option] = option
			}
		}
	}
}

func (p *pluginSettingsForm) changed(index int) bool {
	editors := p.editor.Snapshot.State.Editors.Global
	if p.scope == 1 {
		editors = p.editor.Snapshot.State.Editors.Project
	}
	if !editors[index].Editable {
		return false
	}
	control := &p.controls[p.scope][index]
	if control.reset {
		return true
	}
	baseline := p.editor.Snapshot.State.Editors.Global[index].Input
	if p.scope == 1 {
		baseline = p.editor.Snapshot.State.Editors.Project[index].Input
	}
	switch p.editor.Snapshot.State.Rows[index].Declaration.Kind {
	case "boolean":
		return control.input.On != baseline.On
	case "enum":
		return control.input.Selected != baseline.Selected
	case "multiSelect":
		return !slices.Equal(control.input.Checks, baseline.Checks)
	default:
		return control.text != baseline.Text
	}
}

func (p *pluginSettingsForm) hasDraft() bool {
	for index := range p.controls[p.scope] {
		if p.changed(index) {
			return true
		}
	}
	return false
}

func (p *pluginSettingsForm) edits() ([]core.PluginSettingEdit, error) {
	var edits []core.PluginSettingEdit
	for index := range p.controls[p.scope] {
		if !p.changed(index) {
			continue
		}
		control := &p.controls[p.scope][index]
		declaration := p.editor.Snapshot.State.Rows[index].Declaration
		edit := core.PluginSettingEdit{ID: declaration.ID}
		if !control.reset {
			var value any
			switch declaration.Kind {
			case "boolean":
				value = control.input.On
			case "enum":
				value = declaration.Options[control.input.Selected].Value
			case "multiSelect":
				values := make([]string, 0, len(control.input.Checks))
				for i, checked := range control.input.Checks {
					if checked {
						values = append(values, declaration.Options[i].Value)
					}
				}
				value = values
			default:
				text := control.text
				edit.Text = &text
			}
			if edit.Text == nil {
				data, err := json.Marshal(value)
				if err != nil {
					return nil, err
				}
				edit.Value = data
			}
		}
		edits = append(edits, edit)
	}
	return edits, nil
}

func (p *pluginSettingsForm) save() {
	if p.running || p.stale || !p.loaded || p.loader == nil {
		return
	}
	edits, err := p.edits()
	if err != nil {
		p.failed = err
		if p.report != nil {
			p.report(err)
		}
		return
	}
	if len(edits) == 0 {
		return
	}
	scope := "global"
	if p.scope == 1 {
		scope = "project"
	}
	p.mu.Lock()
	p.op = pluginSettingsOp{editor: p.editor, scope: scope, edits: edits}
	p.mu.Unlock()
	p.running, p.failed, p.saved = true, nil, false
	p.opKey++
}

// act shares the form's one operation with saves. Closing or replacing the form cancels
// the request; a late completion cannot restore an old editor.
func (p *pluginSettingsForm) act(id string, confirmed bool) {
	if _, ok := p.loader.(PluginSettingsActionLoader); !ok || p.running || !p.loaded {
		return
	}
	p.mu.Lock()
	p.op = pluginSettingsOp{editor: p.editor, action: id, confirmed: confirmed, isAction: true}
	p.mu.Unlock()
	p.running, p.acting = true, true
	p.failed = nil
	p.saved = false
	p.actionConfirmation = nil
	p.confirmOpen = false
	p.actionComplete = false
	p.actionCanceled = false
	p.actionUnavailable = ""
	p.opKey++
}

func (p *pluginSettingsForm) sourceChanged() {
	if p.id == "" {
		return
	}
	p.stale = true
	if !p.running && p.hasDraft() && !p.staleReported {
		p.staleReported = true
		if p.report != nil {
			p.report(configfile.ErrConflict)
		}
	}
	// An in-flight save must finish against its captured source. Its own
	// readback is authoritative; no event can clear another form's draft.
	if !p.running && !p.hasDraft() {
		p.load(p.id)
	}
}

// follow keeps the plugin's own text in the window's language. A form that has a draft
// or a request running keeps its text, so a language change never discards an edit; it
// reloads once it is clean. The language check comes first, so a settled form costs one
// comparison per paint.
func (p *pluginSettingsForm) follow(language i18n.Language) {
	p.language = language
	if p.shown == language || !p.loaded || p.running || p.hasDraft() {
		return
	}
	p.load(p.id)
}

// Leaving a surface dismisses transient dialogs, while retaining the drafts for the next
// visit to this plugin.
func (p *pluginSettingsForm) blur() {
	p.actionConfirmation = nil
	p.confirmOpen = false
}
