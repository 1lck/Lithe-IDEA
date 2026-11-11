package workbench

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"strconv"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/fontprefs"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/legacyimport"
	"github.com/1lck/Lithe-IDEA/desktop/internal/settingswindow"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// This file holds the import of an earlier Lithe client's preferences and recent projects,
// which the user starts from the settings menu. The earlier client is still installed and
// used, so its data is only read (package legacyimport). The dialog lists what was found;
// the chosen settings replace the current ones, recent projects join the current list with
// their own times, and both files are read back before the import counts as done.

// legacyImportTimeout bounds reading the earlier client's preferences.
const legacyImportTimeout = kernelCallTimeout

// legacyItem is one thing the import can take.
type legacyItem uint8

const (
	legacyLanguage legacyItem = iota
	legacyTheme
	legacyMinimap
	legacyTabRows
	legacyTerminalShell
	legacyProcessTermination
	legacyEditorFont
	legacyTerminalFont
	legacyRecent
)

// legacyImportState is the import the user asked for. items is allocated when the
// dialog opens and not grown, since each switch is bound to its chosen field by address.
type legacyImportState struct {
	reading, open bool
	found         legacyimport.Found
	items         []legacyImportItem
	// plugins are the earlier client's plugins this client has not installed.
	plugins []legacyimport.Plugin
	// read reads the earlier client's preferences; nil is legacyimport.Read. Tests set it.
	read func(context.Context) (legacyimport.Found, error)
}

type legacyImportItem struct {
	item   legacyItem
	chosen bool
}

// legacyImportMenuItem declares the settings menu's item that starts the import. It is
// disabled while the earlier preferences are read.
func (a *App) legacyImportMenuItem(c ui.C, menu *ui.MenuItems) {
	if menu.Item(i18n.Shared(a.language(), "desktop.legacyImport.menu")).Disabled(a.legacyImport.reading).Clicked() {
		c.After(a.readLegacyImport)
	}
}

// readLegacyImport reads what the earlier client stored, off the window thread, and opens
// the dialog that lists it.
func (a *App) readLegacyImport() {
	s := &a.legacyImport
	if s.reading || s.open {
		return
	}
	s.reading = true
	a.performed("settings.import_legacy", surfaceMenu)
	read := s.read
	if read == nil {
		read = legacyimport.Read
	}
	a.background(nil, legacyImportTimeout, func(ctx context.Context) func(*App) {
		found, err := read(ctx)
		return func(a *App) { a.showLegacyImport(found, err) }
	})
}

func (a *App) showLegacyImport(found legacyimport.Found, err error) {
	s := &a.legacyImport
	s.reading = false
	language := a.language()
	switch {
	case errors.Is(err, legacyimport.ErrNotFound) || (err == nil && found.Empty()):
		a.notifyInfo(i18n.Shared(language, "desktop.legacyImport.none"))
		return
	case err != nil:
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("settings_import_legacy_read", err))
		a.notifyError(i18n.SharedFormat(language, "desktop.legacyImport.readFailed", map[string]string{"error": err.Error()}))
		return
	}
	s.found = found
	s.items = s.items[:0]
	for _, item := range legacyItems(found) {
		s.items = append(s.items, legacyImportItem{item: item, chosen: true})
	}
	s.items = slices.Clip(s.items)
	s.plugins = a.missingLegacyPlugins(found.Plugins)
	if len(s.items) == 0 && len(s.plugins) == 0 {
		a.notifyInfo(i18n.Shared(language, "desktop.legacyImport.none"))
		return
	}
	s.open = true
}

// missingLegacyPlugins are the plugins of plugins this client has not installed.
func (a *App) missingLegacyPlugins(plugins []legacyimport.Plugin) []legacyimport.Plugin {
	var installed map[string]settingswindow.PluginState
	if states := a.pluginState.Load(); states != nil {
		installed = *states
	}
	return slices.DeleteFunc(slices.Clone(plugins), func(plugin legacyimport.Plugin) bool { return installed[plugin.ID].Installed })
}

// legacyPluginsShown is how many plugin names the dialog lists before summing up the rest.
const legacyPluginsShown = 8

// legacyPluginsView lists the earlier client's plugins this client has not installed,
// with the way to the marketplace. Packages are never copied: a plugin is installed again
// from the marketplace, which checks it for this host.
func (a *App) legacyPluginsView(c ui.C) {
	s := &a.legacyImport
	if len(s.plugins) == 0 {
		return
	}
	language := a.language()
	ui.Column(c.Part("legacy-plugins")).FillWidth().Gap(4).PadY(4).Children(func() {
		ui.Text(c, i18n.Shared(language, "desktop.legacyImport.plugins")).Weight(gfx.WeightMedium)
		names := make([]string, 0, legacyPluginsShown+1)
		for _, plugin := range s.plugins[:min(len(s.plugins), legacyPluginsShown)] {
			names = append(names, plugin.Name)
		}
		if rest := len(s.plugins) - legacyPluginsShown; rest > 0 {
			names = append(names, i18n.SharedFormat(language, "desktop.legacyImport.pluginsMore", map[string]string{"count": strconv.Itoa(rest)}))
		}
		ui.Paragraph(c, strings.Join(names, " · "), 4).FontSize(a.theme.Metrics.FontSizeS)
		ui.Paragraph(c, i18n.Shared(language, "desktop.legacyImport.pluginsHelp"), 3).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
		if ui.Button(c.Part("marketplace"), i18n.Shared(language, "desktop.legacyImport.openMarketplace")).Outline().Small().Clicked() {
			c.After(func() { a.openPluginSettings(surfaceButton) })
		}
	})
}

// legacyItems lists what found holds, in the dialog's order.
func legacyItems(found legacyimport.Found) []legacyItem {
	present := []bool{
		legacyLanguage:           found.Language != nil,
		legacyTheme:              found.Theme != nil,
		legacyMinimap:            found.HideMinimap != nil,
		legacyTabRows:            found.EditorTabRows != nil,
		legacyTerminalShell:      found.TerminalShell != nil,
		legacyProcessTermination: found.ProcessTermination != nil,
		legacyEditorFont:         found.EditorFont != nil,
		legacyTerminalFont:       found.TerminalFont != nil,
		legacyRecent:             len(found.Recent) > 0,
	}
	var items []legacyItem
	for item, ok := range present {
		if ok {
			items = append(items, legacyItem(item))
		}
	}
	return items
}

// legacyItemText is the label of item and the value found for it.
func (a *App) legacyItemText(item legacyItem) (label, value string) {
	language, f := a.language(), &a.legacyImport.found
	switch item {
	case legacyLanguage:
		parsed, _ := i18n.Parse(*f.Language)
		return i18n.Shared(language, "desktop.legacyImport.language"), parsed.Native()
	case legacyTheme:
		value := i18n.Shared(language, "desktop.legacyImport.themeSystem")
		switch themeChoice(*f.Theme) {
		case themeLight:
			value = i18n.Shared(language, "desktop.legacyImport.themeLight")
		case themeDark:
			value = i18n.Shared(language, "desktop.legacyImport.themeDark")
		}
		return i18n.Shared(language, "desktop.legacyImport.theme"), value
	case legacyMinimap:
		value := i18n.Shared(language, "desktop.legacyImport.shown")
		if *f.HideMinimap {
			value = i18n.Shared(language, "desktop.legacyImport.hidden")
		}
		return i18n.Shared(language, "desktop.legacyImport.minimap"), value
	case legacyTabRows:
		value := i18n.Shared(language, "desktop.legacyImport.tabsSingle")
		if *f.EditorTabRows == settingswindow.TabRowsMultiple {
			value = i18n.Shared(language, "desktop.legacyImport.tabsMultiple")
		}
		return i18n.Shared(language, "desktop.legacyImport.tabRows"), value
	case legacyTerminalShell:
		value := *f.TerminalShell
		if value == "" {
			value = i18n.Shared(language, "desktop.legacyImport.shellAutomatic")
		}
		return i18n.Shared(language, "desktop.legacyImport.terminalShell"), value
	case legacyProcessTermination:
		return i18n.Shared(language, "desktop.legacyImport.processTermination"), ""
	case legacyEditorFont:
		return i18n.Shared(language, "desktop.legacyImport.editorFont"), a.legacyFontText(*f.EditorFont)
	case legacyTerminalFont:
		return i18n.Shared(language, "desktop.legacyImport.terminalFont"), a.legacyFontText(*f.TerminalFont)
	case legacyRecent:
		return i18n.Shared(language, "desktop.legacyImport.recent"),
			i18n.SharedFormat(language, "desktop.legacyImport.recentCount", map[string]string{"count": strconv.Itoa(len(f.Recent))})
	}
	return "", ""
}

func (a *App) legacyFontText(font legacyimport.Font) string {
	family := font.Family
	if family == "" {
		family = i18n.Shared(a.language(), "desktop.settings.fontsSystemDefault")
	}
	if font.Size <= 0 {
		return family
	}
	return fmt.Sprintf("%s · %g pt", family, font.Size)
}

// legacyImportView declares the dialog that lists what the earlier client stored.
func (a *App) legacyImportView(c ui.C) {
	s := &a.legacyImport
	if !s.open {
		return
	}
	language := a.language()
	chosen := slices.ContainsFunc(s.items, func(item legacyImportItem) bool { return item.chosen })
	confirmed, cancelled := false, false
	spec := ui.ModalSpec{Description: i18n.SharedFormat(language, "desktop.legacyImport.description", map[string]string{"source": s.found.Source}), Width: 480}
	closed := ui.ModalWith(c, &s.open, i18n.Shared(language, "desktop.legacyImport.title"), spec, func() {
		ui.Column(c.Part("legacy-import")).FillWidth().Gap(6).Children(func() {
			for index := range s.items {
				entry := &s.items[index]
				label, value := a.legacyItemText(entry.item)
				k := c.Key(strconv.Itoa(int(entry.item)))
				ui.Row(k).FillWidth().Items(ui.Center).Gap(8).Children(func() {
					ui.Switch(k.Part("chosen"), &entry.chosen, label).Grow(1).Shrink(1).MinWidth(0)
					if value != "" {
						ui.Text(k, value).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Ellipsis().Shrink(1).MinWidth(0)
					}
				})
			}
			a.legacyPluginsView(c)
		})
	}, func() {
		cancelled = ui.Button(c, i18n.Shared(language, "desktop.git.cancel")).Outline().Clicked()
		confirmed = ui.Button(c, i18n.Shared(language, "desktop.legacyImport.confirm")).Disabled(!chosen).AutoFocus().Clicked()
	})
	switch {
	case confirmed:
		c.After(a.applyLegacyImport)
	case closed || cancelled:
		s.open = false
	}
}

// applyLegacyImport applies the chosen items through the same setters the settings
// window uses, then reads both files back.
func (a *App) applyLegacyImport() {
	s := &a.legacyImport
	if !s.open {
		return
	}
	s.open = false
	f := s.found
	chosen := map[legacyItem]bool{}
	for _, entry := range s.items {
		chosen[entry.item] = entry.chosen
	}
	a.performed("settings.import_legacy_apply", surfaceButton)
	if chosen[legacyLanguage] {
		a.setLanguage(*f.Language)
	}
	if chosen[legacyTheme] {
		a.setTheme(themeChoice(*f.Theme))
	}
	if chosen[legacyMinimap] {
		a.settings.HideMinimap = *f.HideMinimap
	}
	if chosen[legacyTabRows] {
		a.setTabRows(*f.EditorTabRows)
	}
	if chosen[legacyTerminalShell] {
		a.setTerminalShell(*f.TerminalShell)
	}
	if chosen[legacyProcessTermination] {
		value := settingswindow.ProcessTermination{RunServicesOnExit: f.ProcessTermination.RunServicesOnExit, TerminalOnQuit: f.ProcessTermination.TerminalOnQuit}
		if !f.ProcessTermination.ConfirmTerminalTabClose {
			value.ConfirmTerminalTabClose = new(false)
		}
		a.setProcessTermination(value)
	}
	if fonts, ok := legacyFonts(a.settings.Fonts, f, chosen[legacyEditorFont], chosen[legacyTerminalFont]); ok {
		a.setFonts(fonts)
	}
	a.saveSettings()
	language := a.language()
	if err := a.verifySettingsSaved(); err != nil {
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("settings_import_legacy_apply", err))
		a.notifyError(i18n.SharedFormat(language, "desktop.legacyImport.failed", map[string]string{"error": err.Error()}))
		return
	}
	imported := 0
	if chosen[legacyRecent] {
		entries := slices.Clone(a.recent)
		for _, recent := range f.Recent {
			entries = append(entries, core.RecentProject{Path: recent.Path, LastOpenedAt: recent.OpenedAt})
		}
		before := len(a.recent)
		a.reduceRecent(entries, core.NormalizeRecent(), true)
		if err := a.verifyRecentSaved(); err != nil {
			a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("settings_import_legacy_recent", err))
			a.notifyError(i18n.SharedFormat(language, "desktop.legacyImport.failed", map[string]string{"error": err.Error()}))
			return
		}
		imported = max(len(a.recent)-before, 0)
	}
	a.notifySuccess(i18n.SharedFormat(language, "desktop.legacyImport.done", map[string]string{"recent": strconv.Itoa(imported)}))
}

// legacyFonts puts the chosen earlier fonts in front of the current list, each for its
// own scope, so normalizing gives that scope to them and keeps the rest as they are. A
// font without a size keeps the scope's current size.
func legacyFonts(current []fontprefs.Font, f legacyimport.Found, editor, terminal bool) ([]fontprefs.Font, bool) {
	current = fontprefs.Normalize(current)
	var fonts []fontprefs.Font
	add := func(font *legacyimport.Font, scope fontprefs.Scope) {
		resolved := fontprefs.For(current, scope)
		size := font.Size
		if size <= 0 {
			size = resolved.Size
		}
		fonts = append(fonts, fontprefs.Font{Family: font.Family, Size: size, LineSpacing: resolved.LineSpacing, Ligatures: resolved.Ligatures, Scopes: []fontprefs.Scope{scope}})
	}
	if editor && f.EditorFont != nil {
		add(f.EditorFont, fontprefs.Editor)
	}
	if terminal && f.TerminalFont != nil {
		add(f.TerminalFont, fontprefs.Terminal)
	}
	if fonts == nil {
		return nil, false
	}
	return append(fonts, current...), true
}

// verifySettingsSaved reads settingsFile back and compares it with the settings in use.
func (a *App) verifySettingsSaved() error {
	var stored settings
	if _, err := a.store.Load(settingsFile, &stored); err != nil {
		return err
	}
	return sameJSON(stored, a.settings)
}

// verifyRecentSaved reads the recent project file back and compares it with the list in use.
func (a *App) verifyRecentSaved() error {
	var stored []core.RecentProject
	if _, err := a.store.Load(recentFile, &stored); err != nil {
		return err
	}
	return sameJSON(stored, a.recent)
}

func sameJSON(stored, current any) error {
	left, err := json.Marshal(stored)
	if err != nil {
		return err
	}
	right, err := json.Marshal(current)
	if err != nil {
		return err
	}
	if !bytes.Equal(left, right) {
		return errors.New("the saved file does not hold the imported values")
	}
	return nil
}
