package workbench

import (
	"context"
	"encoding/json"
	"errors"
	"os"

	"github.com/1lck/Lithe-IDEA/desktop/internal/configfile"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginsettings"
)

// pluginSettingsSources performs native I/O on the settings worker. The root pointer
// is an immutable publication from the workbench window, shared with toolchains.
type pluginSettingsSources struct{ app *App }

func (s pluginSettingsSources) Load(ctx context.Context, id string, language i18n.Language) (editor pluginservice.SettingsEditor, err error) {
	defer func() { (settingsToolchains{app: s.app}).recordFailure(ctx, "plugin_settings_load", err) }()
	root := ""
	if current := s.app.toolchainRoot.Load(); current != nil {
		root = *current
	}
	editor, err = s.app.plugins.LoadSettingsEditor(ctx, id, root, language.Code())
	if err == nil {
		// A skipped translation falls back to the next candidate or to manifest
		// text; the page still loads, so this is a degraded read, not a failure.
		if len(editor.Snapshot.LocalizationReadFailures()) > 0 {
			s.app.operationRejectedIn(ctx, "plugin_settings_load", "localization_unreadable")
		}
		if localization := editor.Snapshot.State.Localization; localization != nil && len(localization.Rejected) > 0 {
			s.app.operationRejectedIn(ctx, "plugin_settings_load", "invalid_localization")
		}
		invalid := false
		for _, value := range editor.Snapshot.State.Editors.Global {
			invalid = invalid || value.InvalidStored
		}
		for _, value := range editor.Snapshot.State.Editors.Project {
			invalid = invalid || value.InvalidStored
		}
		if invalid {
			s.app.operationRejectedIn(ctx, "plugin_settings_load", "invalid_stored_values")
		}
	}
	return editor, err
}

func (s pluginSettingsSources) Save(ctx context.Context, editor pluginservice.SettingsEditor, scope string, edits []core.PluginSettingEdit) (result pluginsettings.SaveResult, err error) {
	defer func() { (settingsToolchains{app: s.app}).recordFailure(ctx, "plugin_settings_save", err) }()
	check := func() error {
		if scope != "project" {
			return nil
		}
		root := s.app.toolchainRoot.Load()
		if root == nil || *root == "" || editor.Snapshot.Workspace() == "" {
			return configfile.ErrConflict
		}
		source, err := os.Stat(editor.Snapshot.Workspace())
		if err != nil {
			return errors.Join(configfile.ErrConflict, err)
		}
		current, err := os.Stat(*root)
		if err != nil {
			return errors.Join(configfile.ErrConflict, err)
		}
		if !os.SameFile(source, current) {
			return configfile.ErrConflict
		}
		return nil
	}
	result, err = s.app.plugins.SaveSettingsEditor(ctx, editor, scope, edits, check)
	// Publication can succeed even if readback or cleanup fails. Its validated
	// effects still belong to the committed source, independent of page lifetime.
	if result.Committed {
		effects := append([]string(nil), result.Effects...)
		err = errors.Join(err, s.app.publishSettings(editor, scope, effects))
	}
	return result, err
}

// View sends one event of a settings region's view to the plugin's backend (API-13, API-19).
// The event already carries the page's settings, so nothing is read for it here; the
// workspace is the one the editor was read for. Every failure is logged, that of a close
// event too, whose answer the view ignores; a call the closing page cancelled is not.
func (s pluginSettingsSources) View(ctx context.Context, editor pluginservice.SettingsEditor, region, function string, event, view json.RawMessage, closing bool) (json.RawMessage, bool, error) {
	drawn, changed, err := s.app.plugins.CallView(ctx, pluginservice.SettingsViewCall(editor, region, function, editor.Snapshot.Workspace(), event, view, closing))
	s.app.viewCallFailed(ctx, "plugin_settings_view", err)
	return drawn, changed, err
}

func (s pluginSettingsSources) WatchView(pluginID, instance string, refresh func()) func() {
	return s.app.plugins.WatchView(pluginID, instance, refresh)
}

func (s pluginSettingsSources) PluginWorkflow(ctx context.Context, request, result any) error {
	return s.app.plugins.PluginWorkflow(ctx, request, result)
}
