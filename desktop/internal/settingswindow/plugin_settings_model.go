package settingswindow

import (
	"context"
	"encoding/json"
	"errors"
	"slices"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/configfile"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginsettings"
	"github.com/vivaui/viva/ui"
)

// A control owns its draft, IME editor and popup. Core supplies input/reset
// projections; native text is sent back unparsed on explicit Save.
type pluginSettingControl struct {
	field       ui.Field
	input       core.PluginSettingInput
	selectState ui.SelectState
	reset       bool
}

func (c *pluginSettingControl) apply(input core.PluginSettingInput) {
	c.input = input
	c.input.Checks = append([]bool(nil), input.Checks...)
	c.field.SetText(input.Text)
	c.reset = false
}

type pluginSettingsResult struct {
	generation uint64
	editor     pluginservice.SettingsEditor
	save       pluginsettings.SaveResult
	saved      bool
	action     *pluginservice.SettingsActionResult
	err        error
}

// pluginSettingLayout caches native row geometry for the Core-ordered form.
type pluginSettingLayout struct {
	title  string
	row    int
	action bool
	offset float32
	height float32
}

type pluginSettingsForm struct {
	pageKey            string
	stale              bool
	staleReported      bool
	acting             bool
	actionComplete     bool
	actionCanceled     bool
	actionConfirmation *core.PluginSettingsActionPlan
	actionUnavailable  string
	layout             []pluginSettingLayout
	height             float32
	report             func(error)
	loader             PluginSettingsLoader
	wake               func()
	results            chan pluginSettingsResult
	generation         uint64
	cancel             context.CancelFunc
	running            bool
	pending            string
	id                 string
	loaded             bool
	failed             error
	saved              bool
	// scope and both drafts are view state; switching scope does not lose edits.
	scope       int
	scopeSelect ui.SelectState
	editor      pluginservice.SettingsEditor
	controls    [2][]pluginSettingControl
}

func newPluginSettingsForm(loader PluginSettingsLoader, wake func()) pluginSettingsForm {
	return pluginSettingsForm{loader: loader, wake: wake, results: make(chan pluginSettingsResult, 1)}
}

func (p *pluginSettingsForm) load(id string) {
	p.stale = false
	p.staleReported = false
	p.actionConfirmation = nil
	p.actionComplete = false
	p.actionCanceled = false
	p.actionUnavailable = ""
	p.acting = false
	if p.loader == nil {
		return
	}
	p.generation++
	if p.cancel != nil {
		p.cancel()
		p.cancel = nil
	}
	p.pending, p.id, p.loaded, p.failed, p.saved = id, id, false, nil, false
	p.controls = [2][]pluginSettingControl{}
	p.launch()
}

// Only one worker can run. Rapid selection cancels the old load and retains
// only the latest request until that worker has returned; no blocked senders.
func (p *pluginSettingsForm) launch() {
	if p.running || p.pending == "" {
		return
	}
	id, generation := p.pending, p.generation
	p.pending, p.running = "", true
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	p.cancel = cancel
	loader, results, wake := p.loader, p.results, p.wake
	go func() {
		defer cancel()
		editor, err := loader.Load(ctx, id)
		results <- pluginSettingsResult{generation: generation, editor: editor, err: err}
		if wake != nil {
			wake()
		}
	}()
}

func (p *pluginSettingsForm) drain() {
	select {
	case result := <-p.results:
		p.running = false
		p.cancel = nil
		if result.generation != p.generation {
			p.launch()
			return
		}
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
				p.actionConfirmation = &plan
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
			return
		}
		if result.err != nil {
			return
		}
		p.editor, p.loaded = result.editor, true
		p.applyScope(0)
		p.applyScope(1)
		p.layoutRows()
		if p.stale {
			p.sourceChanged()
		}
	default:
	}
}

func (p *pluginSettingsForm) layoutRows() {
	p.layout, p.height = nil, 0
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
			p.layout = append(p.layout, pluginSettingLayout{title: section.Title, row: -1, offset: p.height, height: 28})
			p.height += 28
		}
		for _, index := range section.Rows {
			height := float32(110)
			if state.Rows[index].Declaration.Kind == "integer" {
				height = 130
			}
			declaration := &state.Rows[index].Declaration
			if declaration.Kind == "multiSelect" {
				height += float32(len(declaration.Options)) * 26
			}
			p.layout = append(p.layout, pluginSettingLayout{row: index, offset: p.height, height: height})
			p.height += height
		}
		for _, index := range section.Actions {
			p.layout = append(p.layout, pluginSettingLayout{row: index, action: true, offset: p.height, height: 44})
			p.height += 44
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
		p.controls[scope][index].apply(editor.Input)
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
		return control.field.Text() != baseline.Text
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
				text := control.field.Text()
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
	generation, editor, loader, results, wake := p.generation, p.editor, p.loader, p.results, p.wake
	p.running, p.failed, p.saved = true, nil, false
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	p.cancel = cancel
	go func() {
		defer cancel()
		result, err := loader.Save(ctx, editor, scope, edits)
		results <- pluginSettingsResult{generation: generation, save: result, saved: true, err: err}
		if wake != nil {
			wake()
		}
	}()
}

func (p *pluginSettingsForm) close() {
	p.generation++
	p.pending = ""
	if p.cancel != nil {
		p.cancel()
		p.cancel = nil
	}
}

// act shares the form's single worker with loads and saves. Closing or replacing
// the form cancels the request; late completion cannot restore an old editor.
func (p *pluginSettingsForm) act(id string, confirmed bool) {
	loader, ok := p.loader.(PluginSettingsActionLoader)
	if !ok || p.running || !p.loaded {
		return
	}
	p.generation++
	generation, editor := p.generation, p.editor
	p.running, p.acting = true, true
	p.failed = nil
	p.saved = false
	p.actionConfirmation = nil
	p.actionComplete = false
	p.actionCanceled = false
	p.actionUnavailable = ""
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	p.cancel = cancel
	results, wake := p.results, p.wake
	go func() {
		defer cancel()
		result, err := loader.Action(ctx, editor, id, confirmed)
		results <- pluginSettingsResult{generation: generation, action: &result, err: err}
		if wake != nil {
			wake()
		}
	}()
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

// Leaving a surface dismisses transient popups, while retaining native input
// owners and drafts for the next visit to this plugin.
func (p *pluginSettingsForm) blur() {
	p.actionConfirmation = nil
	p.scopeSelect.Open = false
	for scope := range p.controls {
		for index := range p.controls[scope] {
			p.controls[scope][index].selectState.Open = false
		}
	}
}
