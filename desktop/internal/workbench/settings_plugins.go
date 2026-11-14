package workbench

import (
	"context"
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
	defer func() { (settingsToolchains{app: s.app}).recordFailure("plugin_settings_load", err) }()
	root := ""
	if current := s.app.toolchainRoot.Load(); current != nil {
		root = *current
	}
	editor, err = s.app.plugins.LoadSettingsEditor(ctx, id, root, language.Code())
	if err == nil {
		// A skipped translation falls back to the next candidate or to manifest
		// text; the page still loads, so this is a degraded read, not a failure.
		if len(editor.Snapshot.LocalizationReadFailures()) > 0 {
			s.app.emit(core.LevelWarn, pluginSettingsLoadRejectedEvent, pluginSettingsLoadRejected("localization_unreadable"))
		}
		if localization := editor.Snapshot.State.Localization; localization != nil && len(localization.Rejected) > 0 {
			s.app.emit(core.LevelWarn, pluginSettingsLoadRejectedEvent, pluginSettingsLoadRejected("invalid_localization"))
		}
		invalid := false
		for _, value := range editor.Snapshot.State.Editors.Global {
			invalid = invalid || value.InvalidStored
		}
		for _, value := range editor.Snapshot.State.Editors.Project {
			invalid = invalid || value.InvalidStored
		}
		if invalid {
			s.app.emit(core.LevelWarn, pluginSettingsLoadRejectedEvent, pluginSettingsLoadRejected("invalid_stored_values"))
		}
	}
	return editor, err
}

// pluginSettingsLoadRejectedEvent logs a plugin settings read that loaded but refused part of
// what it read: a stored value or a translation file of the package.
const pluginSettingsLoadRejectedEvent = "app.notification.operation_rejected"

// pluginSettingsLoadRejected are the fields of that event; reason is localization_unreadable,
// invalid_localization or invalid_stored_values.
func pluginSettingsLoadRejected(reason string) map[string]any {
	return map[string]any{"operation": "plugin_settings_load", "reason": reason}
}

func (s pluginSettingsSources) Save(ctx context.Context, editor pluginservice.SettingsEditor, scope string, edits []core.PluginSettingEdit) (result pluginsettings.SaveResult, err error) {
	defer func() { (settingsToolchains{app: s.app}).recordFailure("plugin_settings_save", err) }()
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
