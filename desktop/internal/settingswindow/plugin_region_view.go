package settingswindow

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginview"
	"github.com/1lck/Lithe-IDEA/desktop/internal/toolchain"
	"github.com/vivaui/viva/ui"
)

// A settings region (settingRegions, API-19) with a view function shows a plugin view
// (API-13) between the page's header and the plugin's declared rows, which stay. The
// plugin's backend answers each view event with the nodes to draw, Core checks the answer,
// and the window draws it with its own controls (pluginview). Its bound controls, setting
// rows and action buttons are the page's own: they edit the page's draft and run the page's
// actions, and the view never stores a value. The window shows one region at a time, the
// one of the page on screen: the first paint that declares it opens it, and the first that
// does not, because the page, the plugin, its version or the language changed or the window
// closed, closes it. What the view shows lives in memory only and ends with the showing.

// The operations a region's failures are logged under: a view the window cannot read, and a
// canvas image it cannot read. A failed call is logged where the call is made.
const (
	pluginRegionViewOperation  = "plugin_settings_view"
	pluginRegionImageOperation = "plugin_settings_view_image"
)

// regionKey names one showing of a region: a change of any part opens the view anew.
type regionKey struct {
	plugin, version, page, region, function, pkg string
	language                                     i18n.Language
}

// regionView is the region the window shows.
type regionView struct {
	key     regionKey
	session *pluginview.Session
	images  *pluginview.Images
	host    pluginview.Host
	// shown says this paint declared the region.
	shown bool
	// sent is the settings, encoded, that the paint before found, so a paint that finds
	// them changed tells the view. sentHash skips per-frame JSON marshaling when unchanged.
	sent     string
	sentHash uint64
	// picker is the tool whose picker is open, empty when none is; pickerShown says this
	// paint drew it, so a picker whose row the view no longer shows closes.
	picker      string
	pickerShown bool
}

// The tool picker's width, and the height its choices scroll beyond.
const (
	toolPickerWidth     = 560
	toolPickerMaxHeight = 320
)

// pluginRegionOf is the region the form's plugin placed on the page on screen: on a page
// under Build or a contributed page the contributor's, on the plugin's own Settings tab the
// editor's. It is nil when the plugin placed none there.
func (w *window) pluginRegionOf(p *pluginSettingsForm) *core.PluginSettingsRegion {
	if w.dynamicPage == "" {
		return p.editor.Snapshot.State.Region
	}
	page := w.dynamic.selected(w.dynamicPage)
	if page == nil {
		return nil
	}
	for index := range page.Contributors {
		if page.Contributors[index].PluginID == p.id {
			return page.Contributors[index].Region
		}
	}
	return nil
}

// pluginRegion declares the form's region view, when the plugin placed one with a view on
// the page on screen and the host can call it. hasSource says the scope shown has a file
// to write, which bound controls need as the page's rows do.
func (w *window) pluginRegion(c ui.C, p *pluginSettingsForm, hasSource bool) {
	region := w.pluginRegionOf(p)
	function := region.ViewFunction()
	loader, ok := w.ctrl.opts.PluginSettings.(PluginViewLoader)
	if function == "" || !ok || !p.loaded {
		return
	}
	language := w.marketLanguage()
	key := regionKey{
		plugin: p.id, version: p.editor.Snapshot.State.Metadata.Version, page: w.dynamicPage,
		region: region.ID, function: function, pkg: p.editor.Package(), language: language,
	}
	if w.region != nil && w.region.key != key {
		w.closeRegion()
	}
	if w.region == nil {
		w.region = w.openRegion(key, loader, p)
	}
	v := w.region
	v.shown = true
	if hash := p.viewSettingsHash(); hash != v.sentHash {
		v.sentHash = hash
		if sent := p.viewSettingsText(); sent != v.sent {
			v.sent = sent
			v.session.SettingsChanged()
		}
	}
	v.host.Palette, v.host.Language = w.regionPalette(), language
	v.host.Settings = regionSettings{w: w, p: p, hasSource: hasSource}
	v.pickerShown = false
	pluginview.Draw(c.Key("plugin-region:"+region.ID), v.session, &v.host, false)
	if !v.pickerShown {
		v.picker = ""
	}
}

// openRegion makes and opens the view of key. Its calls carry the editor the form holds now,
// whose plugin, version and package the key names, and each event carries the settings the
// form holds when it is sent.
func (w *window) openRegion(key regionKey, loader PluginViewLoader, p *pluginSettingsForm) *regionView {
	// The window's invalidator is installed before the first paint and is safe to call from
	// the call's goroutine.
	inv := &w.inv
	wake := func() { inv.Invalidate() }
	editor, opts := p.editor, w.ctrl.opts
	failed := func(operation string) func(error) {
		return func(err error) { reportSettingsError(opts, operation, err) }
	}
	v := &regionView{
		key:      key,
		images:   pluginview.NewImages(key.pkg, wake, failed(pluginRegionImageOperation)),
		sent:     p.viewSettingsText(),
		sentHash: p.viewSettingsHash(),
	}
	v.session = pluginview.NewSession(pluginview.Options{
		Call: func(ctx context.Context, event, view json.RawMessage, closing bool) (json.RawMessage, bool, error) {
			return loader.View(ctx, editor, key.region, key.function, event, view, closing)
		},
		Params: func() map[string]any {
			return map[string]any{"language": key.language.Code(), "settings": p.viewSettings()}
		},
		Wake:   wake,
		Failed: failed(pluginRegionViewOperation),
		Page: func(ctx context.Context, request, result any) error {
			if workflow, ok := loader.(interface {
				PluginWorkflow(context.Context, any, any) error
			}); ok {
				return workflow.PluginWorkflow(ctx, request, result)
			}
			return errors.New("plugin workflow projection is unavailable")
		},
		Watch: func(instance string, refresh func()) func() {
			if watcher, ok := loader.(PluginViewWatcher); ok {
				return watcher.WatchView(key.plugin, instance, refresh)
			}
			return func() {}
		},
	})
	v.host = pluginview.Host{Icon: pluginview.HostIcon, Images: v.images, Info: w.infoButton}
	v.session.Open()
	return v
}

// closeRegion ends the region's showing and drops the images it read.
func (w *window) closeRegion() {
	if v := w.region; v != nil {
		v.session.Close()
		v.images.Close()
		w.region = nil
	}
}

// endRegion runs at the end of each paint: a region the paint did not declare closes, and
// the one it did is marked as not declared until the next paint declares it.
func (w *window) endRegion() {
	if v := w.region; v != nil {
		if !v.shown {
			w.closeRegion()
			return
		}
		v.shown = false
	}
}

// regionPalette maps the window's look onto the tokens a view names, so a region reads as
// part of the page in the light and the dark theme.
func (w *window) regionPalette() pluginview.Palette {
	p := &w.pal
	return pluginview.Palette{
		Dark: w.dark, Text: p.text, TextSecondary: p.muted, TextMuted: p.subtle,
		Accent: p.accent, Success: p.success, Warning: p.warning, Error: p.danger,
		Surface: p.card, Background: p.window, Sidebar: p.sidebar, Line: p.line,
		Hover: p.hover, Selection: p.selection, Badge: w.theme.Secondary,
		Popover: w.theme.Popover, PopoverText: w.theme.PopoverForeground,
	}
}

// regionSettings is the page a region is drawn on: the form's rows, drafts and actions, and
// the toolchain pages' rows.
type regionSettings struct {
	w         *window
	p         *pluginSettingsForm
	hasSource bool
}

// row is the index of the declared setting in the form, or -1.
func (s regionSettings) row(setting string) int {
	rows := s.p.editor.Snapshot.State.Rows
	for index := range rows {
		if rows[index].Declaration.ID == setting {
			if index < len(s.p.controls[s.p.scope]) {
				return index
			}
			break
		}
	}
	return -1
}

func (s regionSettings) Row(c ui.C, setting string, key pluginview.NodeKey) bool {
	index := s.row(setting)
	if index < 0 {
		return false
	}
	s.w.pluginSettingRow(key.Apply(c), index, s.hasSource)
	return true
}

// toolScope is the toolchain scope beside the scope the page shows: the project's pins beside
// the project's settings, the machine's defaults beside the global ones. A window without the
// two scopes has the one it has.
func (s regionSettings) toolScope(t *toolchainState) *toolchainScope {
	name := scopeGlobal
	if s.p.scope == 1 {
		name = scopeProject
	}
	if scope := t.scopes[name]; scope != nil {
		return scope
	}
	return t.current()
}

// Tool draws the toolchains list's row for the tool, in the toolchain scope beside the scope
// the page shows. Pressing it opens the Toolchains page in that scope with the tool chosen;
// with choose, a tool the user may pin opens its picker instead (toolPicker).
func (s regionSettings) Tool(c ui.C, tool string, choose bool, key pluginview.NodeKey) bool {
	w := s.w
	t := w.toolchains
	if t == nil || !t.available() {
		return false
	}
	t.ensureLoaded()
	scope := s.toolScope(t)
	if scope == nil || !scope.loaded {
		return false
	}
	entry := t.toolchainEntryFor(scope, tool)
	if entry == nil {
		return false
	}
	b := &w.bp
	language := w.marketLanguage()
	v := w.region
	// Only a tool the scope holds and the user may pin has choices; any other row stays the
	// way to the Toolchains page, which says why.
	fresh := scope.tool(tool)
	picks := choose && v != nil && fresh != nil && !fresh.ManagedOnly
	open := picks && v.picker == tool
	row := ui.ButtonBase(key.Apply(c), entry.tool.DisplayName).FillWidth().Height(toolchainToolRow).PadSides(0, 12, 0, 14).
		Gap(9).Items(ui.Center).Radius(6).Border(1, b.line).Hover(ui.Look{}.Background(b.hover))
	if open {
		row = row.Border(1, b.accent)
	}
	clicked := row.Clicked()
	row.Children(func() {
		w.toolchainToolContent(c, language, scope, entry, "")
		if picks {
			ui.Icon(c, icons.ChevronDown).Size(14, 14).Color(b.sub).Shrink(0)
		}
	})
	if !picks {
		if clicked {
			s.revealTool(t, scope, tool)
		}
		return true
	}
	if open {
		v.pickerShown = true
		s.toolPicker(c.Part("picker"), row, language, scope, fresh, &open)
	} else if clicked {
		// The add-directory field checks in the Toolchains page's scope, so the page follows
		// the picker's.
		t.setScope(scope.name)
		open, v.pickerShown = true, true
	}
	switch {
	case open:
		v.picker = tool
	case v.picker == tool:
		v.picker = ""
	}
	return true
}

// revealTool opens the Toolchains page in the scope with the tool chosen.
func (s regionSettings) revealTool(t *toolchainState, scope *toolchainScope, tool string) {
	t.setScope(scope.name)
	t.reveal(tool, t.view.group(tool))
	s.w.openBuildChild(pageToolchains)
}

// toolPicker is the menu a tool row with choose opens, like an IDE's interpreter menu: the
// Toolchains page's choices for the tool in the scope (the automatic or inherited choice, then
// every home the scope knows with its version and sources), the field that adds a directory,
// and the way to the page. A choice is the scope's draft, which the footer's Apply writes and
// Cancel drops, and it closes the menu.
func (s regionSettings) toolPicker(c ui.C, row ui.Box, language i18n.Language, scope *toolchainScope, tool *toolchain.Tool, open *bool) {
	w := s.w
	t := w.toolchains
	title := i18n.Shared(language, "desktop.buildSettings.optionsGlobal")
	if scope.name == scopeProject {
		title = i18n.Shared(language, "desktop.buildSettings.optionsProject")
	}
	spec := ui.PopoverSpec{Align: ui.Start, Width: toolPickerWidth, ConsumeOutsidePress: true, Title: title}
	ui.Popover(c, row, open, spec, func() {
		before := scope.wanted(tool.ID)
		current := toolchainCurrent(tool)
		ui.Scroll(c.Part("choices")).Scrollbars().FillWidth().MaxHeight(toolPickerMaxHeight).Children(func() {
			for _, option := range t.options(language, scope, tool) {
				w.toolchainOption(c.Key("option:"+option.home), language, scope, tool, option, option.home == before, current)
			}
		})
		w.toolchainAddRow(c.Part("add"), language, scope, tool)
		ui.Row(c).FillWidth().PadX(8).PadY(4).Items(ui.Center).Children(func() {
			if w.button(c.Part("toolchains"), buttonLinkSmall, i18n.Shared(language, "desktop.pluginView.toolPickerToolchains"), false) {
				*open = false
				s.revealTool(t, scope, tool.ID)
			}
		})
		if scope.wanted(tool.ID) != before {
			*open = false
		}
	})
}

// Binding is the draft of a declared setting a control can edit: a text, file, directory or
// integer setting's text, a boolean's switch and an enum's choice.
func (s regionSettings) Binding(setting string) (pluginview.Binding, bool) {
	p := s.p
	index := s.row(setting)
	if index < 0 {
		return pluginview.Binding{}, false
	}
	declaration := &p.editor.Snapshot.State.Rows[index].Declaration
	control := &p.controls[p.scope][index]
	binding := pluginview.Binding{
		Title:    declaration.Title,
		Editable: !p.running && p.loaded && p.scopeEditor(index).Editable && s.hasSource,
		Value: func() any {
			value, _ := p.draftValue(index)
			return value
		},
		Edited: func() {
			control.reset = false
			p.saved = false
		},
	}
	switch declaration.Kind {
	case "boolean":
		binding.On = &control.input.On
	case "enum":
		binding.Selected, binding.Options = &control.input.Selected, control.options
		binding.OptionLabel = func(option int) string {
			if option >= 0 && option < len(declaration.Options) {
				return declaration.Options[option].Title
			}
			return ""
		}
	case "text", "file", "directory", "integer":
		binding.Text = &control.text
	default:
		return pluginview.Binding{}, false
	}
	return binding, true
}

func (s regionSettings) Action(action string) {
	s.p.act(action, false)
}

func (s regionSettings) ActionEnabled(action string) bool {
	_, ok := s.p.loader.(PluginSettingsActionLoader)
	return ok && !s.p.running && s.p.loaded
}

// scopeEditor is Core's projection of the setting in the scope shown.
func (p *pluginSettingsForm) scopeEditor(index int) core.PluginSettingEditorValue {
	if p.scope == 1 {
		return p.editor.Snapshot.State.Editors.Project[index]
	}
	return p.editor.Snapshot.State.Editors.Global[index]
}

// draftValue is the draft of a setting in the scope shown, typed as the setting stores it,
// as a view event carries it: a number for an integer and the nonblank lines of a list.
// ok is false for a draft that has no such value, an integer the text does not spell.
func (p *pluginSettingsForm) draftValue(index int) (any, bool) {
	control := &p.controls[p.scope][index]
	declaration := &p.editor.Snapshot.State.Rows[index].Declaration
	switch declaration.Kind {
	case "boolean":
		return control.input.On, true
	case "enum":
		if selected := control.input.Selected; selected >= 0 && selected < len(declaration.Options) {
			return declaration.Options[selected].Value, true
		}
		return nil, false
	case "multiSelect":
		values := []string{}
		for option, checked := range control.input.Checks {
			if checked && option < len(declaration.Options) {
				values = append(values, declaration.Options[option].Value)
			}
		}
		return values, true
	case "integer":
		value, err := strconv.ParseInt(strings.TrimSpace(control.text), 10, 64)
		return value, err == nil
	case "stringList", "fileList":
		// A list is edited one item per line, and keeps its spaces and path spelling.
		values := []string{}
		for _, line := range strings.Split(control.text, "\n") {
			if strings.TrimSpace(line) != "" {
				values = append(values, line)
			}
		}
		return values, true
	case "text", "file", "directory":
		return control.text, true
	}
	return nil, false
}

// viewSettings are the plugin's values a region's event carries: what is in force in the
// workspace, and the drafts of the scope shown that differ from it, by setting ID. A reset
// row's draft is the value the reset leaves; a draft that has no typed value is left out.
func (p *pluginSettingsForm) viewSettings() pluginservice.ViewSettings {
	settings := pluginservice.ViewSettings{Effective: map[string]json.RawMessage{}, Draft: map[string]json.RawMessage{}}
	rows := p.editor.Snapshot.State.Rows
	for index := range rows {
		if value := rows[index].Effective.Value; len(value) > 0 {
			settings.Effective[rows[index].Declaration.ID] = value
		}
	}
	for index := range p.controls[p.scope] {
		if index >= len(rows) || !p.changed(index) {
			continue
		}
		id := rows[index].Declaration.ID
		if p.controls[p.scope][index].reset {
			if value := p.scopeEditor(index).ResetValue; len(value) > 0 {
				settings.Draft[id] = value
			}
			continue
		}
		value, ok := p.draftValue(index)
		if !ok {
			continue
		}
		data, err := json.Marshal(value)
		if err != nil {
			p.reportViewSettings(err)
			continue
		}
		settings.Draft[id] = data
	}
	return settings
}

// reportViewSettings logs settings a view event cannot carry. The drafts are booleans, text,
// numbers and lists of text, and the values in force Core's JSON, so this means a bug.
func (p *pluginSettingsForm) reportViewSettings(err error) {
	if p.report != nil {
		p.report(fmt.Errorf("settingswindow: encode the settings of a view event: %w", err))
	}
}

// viewSettingsHash computes an allocation-free FNV-64a digest over every setting and draft
// field that viewSettings depends on, allowing pluginRegion to skip per-frame json.Marshal
// while drafts are steady.
func (p *pluginSettingsForm) viewSettingsHash() uint64 {
	const (
		offset64 uint64 = 14695981039346656037
		prime64  uint64 = 1099511628211
	)
	h := offset64
	writeByte := func(b byte) {
		h ^= uint64(b)
		h *= prime64
	}
	writeUint64 := func(v uint64) {
		for i := 0; i < 8; i++ {
			writeByte(byte(v))
			v >>= 8
		}
	}
	writeBool := func(v bool) {
		if v {
			writeByte(1)
		} else {
			writeByte(0)
		}
	}
	writeBytes := func(b []byte) {
		writeUint64(uint64(len(b)))
		for _, c := range b {
			writeByte(c)
		}
	}
	writeString := func(s string) {
		writeUint64(uint64(len(s)))
		for i := 0; i < len(s); i++ {
			writeByte(s[i])
		}
	}

	writeUint64(uint64(p.scope))
	writeString(p.editor.Snapshot.State.Metadata.Version)

	rows := p.editor.Snapshot.State.Rows
	writeUint64(uint64(len(rows)))
	for index := range rows {
		writeString(rows[index].Declaration.ID)
		writeString(rows[index].Declaration.Kind)
		writeBytes(rows[index].Effective.Value)
	}

	editors := p.editor.Snapshot.State.Editors.Global
	if p.scope == 1 {
		editors = p.editor.Snapshot.State.Editors.Project
	}
	writeUint64(uint64(len(editors)))
	for index := range editors {
		editor := &editors[index]
		writeBool(editor.Editable)
		writeBytes(editor.ResetValue)
		writeString(editor.Input.Text)
		writeBool(editor.Input.On)
		writeUint64(uint64(editor.Input.Selected))
		writeUint64(uint64(len(editor.Input.Checks)))
		for _, checked := range editor.Input.Checks {
			writeBool(checked)
		}
	}

	var controls []pluginSettingControl
	if p.scope >= 0 && p.scope < len(p.controls) {
		controls = p.controls[p.scope]
	}
	writeUint64(uint64(len(controls)))
	for index := range controls {
		control := &controls[index]
		writeBool(control.reset)
		writeString(control.text)
		writeBool(control.input.On)
		writeUint64(uint64(control.input.Selected))
		writeUint64(uint64(len(control.input.Checks)))
		for _, checked := range control.input.Checks {
			writeBool(checked)
		}
	}
	return h
}

// viewSettingsText is viewSettings encoded, which a paint compares with the last one; JSON
// sorts the IDs, so the same values encode the same.
func (p *pluginSettingsForm) viewSettingsText() string {
	data, err := json.Marshal(p.viewSettings())
	if err != nil {
		p.reportViewSettings(err)
		return ""
	}
	return string(data)
}
