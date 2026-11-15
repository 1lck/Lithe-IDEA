package workbench

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/configfile"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/installedpackage"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginsettings"
)

func (s pluginSettingsSources) sourceSettingsCall(ctx context.Context, editor pluginservice.SettingsEditor, action string, params json.RawMessage, editing bool) (json.RawMessage, error) {
	check := s.actionWorkspaceCheck(editor)
	plan, err := s.app.plugins.PlanSettingsEditorAction(ctx, editor, action, true, check)
	if err != nil {
		return nil, err
	}
	if plan.Kind != "invoke" || !plan.SourceEditor {
		return nil, configfile.ErrConflict
	}
	if params == nil {
		params = plan.Params
	}
	function := plan.Function
	if editing {
		function = plan.EditFunction
	}
	result, err := s.app.plugins.CallFromPage(ctx, plan.PluginID, function, params, editor.Snapshot.Workspace(), nil)
	if err != nil {
		return nil, err
	}
	current, err := s.app.plugins.PlanSettingsEditorAction(ctx, editor, action, true, check)
	if err != nil {
		return nil, err
	}
	if current.Kind != "invoke" || current.Function != plan.Function || current.EditFunction != plan.EditFunction || !current.SourceEditor {
		return nil, configfile.ErrConflict
	}
	return result, nil
}

func (s pluginSettingsSources) readSourceSettings(ctx context.Context, editor pluginservice.SettingsEditor, action string, published map[string]string) (pluginsettings.SourceEditor, error) {
	plan, err := s.app.plugins.PlanSettingsEditorAction(ctx, editor, action, true, s.actionWorkspaceCheck(editor))
	if err != nil {
		return pluginsettings.SourceEditor{}, err
	}
	environment, err := s.sourceSettingsContext(ctx, editor, plan, len(published) > 0)
	if err != nil {
		return pluginsettings.SourceEditor{}, err
	}
	request := struct {
		Operation string              `json:"operation,omitempty"`
		Context   sourceEditorContext `json:"context"`
	}{Context: environment}
	if len(published) > 0 {
		request.Operation = "readAfterSave"
	}
	params, err := json.Marshal(request)
	if err != nil {
		return pluginsettings.SourceEditor{}, err
	}
	raw, err := s.sourceSettingsCall(ctx, editor, action, params, false)
	if err != nil {
		return pluginsettings.SourceEditor{}, err
	}
	state, err := s.app.kernel.ReadSourceSettings(ctx, raw)
	if err != nil {
		return pluginsettings.SourceEditor{}, err
	}
	for id, revision := range published {
		found := false
		for _, source := range state.Snapshot.Sources {
			if source.ID == id && source.Revision == revision {
				found = true
				break
			}
		}
		if !found {
			return pluginsettings.SourceEditor{}, configfile.ErrConflict
		}
	}
	// The plugin store and the running application's installation are immutable.
	// macOS resources are siblings of MacOS inside the enclosing .app bundle;
	// Windows resources live beside the executable in the installation directory.
	installation, err := installedpackage.Root()
	if err != nil {
		return pluginsettings.SourceEditor{}, err
	}
	return pluginsettings.CaptureSources(ctx, editor.Snapshot.Workspace(), state, []string{s.app.plugins.Root, installation})
}

// SaveSources runs entirely on the settings worker. The source editor retains
// its private baseline, and every publication rechecks package and workspace.
func (s pluginSettingsSources) SaveSources(ctx context.Context, editor pluginservice.SettingsEditor, action string, sources pluginsettings.SourceEditor, edits []core.SourceSettingsEdits) (updated pluginsettings.SourceEditor, err error) {
	ctx = s.app.performedIn(ctx, "plugin.saveNativeSettings", surfaceButton)
	defer func() {
		if errors.Is(err, pluginsettings.ErrSourcesCommitted) {
			s.app.operationFailedIn(ctx, "plugin_settings_source_save", err)
		} else {
			(settingsToolchains{app: s.app}).recordFailure(ctx, "plugin_settings_source_save", err)
		}
	}()
	check := func() error {
		plan, err := s.app.plugins.PlanSettingsEditorAction(ctx, editor, action, true, s.actionWorkspaceCheck(editor))
		if err != nil {
			return err
		}
		if plan.Kind != "invoke" || !plan.SourceEditor {
			return configfile.ErrConflict
		}
		return nil
	}
	published, err := sources.Apply(ctx, s.app.kernel, edits, func(ctx context.Context, params json.RawMessage) (json.RawMessage, error) {
		return s.sourceSettingsCall(ctx, editor, action, params, true)
	}, check)
	if err != nil {
		return sources, err
	}
	updated, err = s.readSourceSettings(ctx, editor, action, published)
	if err != nil && len(published) > 0 {
		err = errors.Join(pluginsettings.ErrSourcesCommitted, err)
	}
	return updated, err
}

// Only native session handles are selected here. Source semantics, grouping and
// declaration validation belong to Core; project facts come from the build engine.
type sourceEditorBuild struct {
	Root    string                     `json:"root"`
	Options map[string]json.RawMessage `json:"options"`
	Tool    core.BuildTool             `json:"tool"`
	Model   sourceEditorProjectModel   `json:"model"`
}

// Source queries receive only the upstream project's normalized facts. Task,
// run and content-root arrays do not cross this separate settings wire.
type sourceEditorProjectModel struct {
	Projects []core.BuildProject `json:"projects"`
}
type sourceEditorContext struct {
	Language string              `json:"language"`
	Builds   []sourceEditorBuild `json:"builds"`
}

func (s pluginSettingsSources) sourceSettingsContext(ctx context.Context, editor pluginservice.SettingsEditor, plan core.PluginSettingsActionPlan, refresh bool) (sourceEditorContext, error) {
	result := sourceEditorContext{Builds: []sourceEditorBuild{}}
	if editor.Snapshot.State.Localization != nil {
		result.Language = editor.Snapshot.State.Localization.Language
	}
	if plan.LanguageID == "" && plan.BuildSystemID == "" {
		return result, nil
	}
	type captured struct {
		messages  i18n.BuildMessages
		project   *project
		instances []buildInstance
		loading   bool
		failure   string
	}
	timer := time.NewTicker(100 * time.Millisecond)
	defer timer.Stop()
	var current captured
	for {
		reply := make(chan captured, 1)
		s.app.post(func(a *App) {
			p := a.project
			if p == nil {
				reply <- captured{}
				return
			}
			if plan.LanguageID != "" {
				a.startPluginServer(plan.LanguageID)
			}
			if plan.BuildSystemID != "" && !p.build.loaded && !p.build.loading {
				a.loadBuildSystems(p)
			}
			// Copy native handles on their owning thread. Their tool/options identities
			// remain bound to this captured workspace generation.
			reply <- captured{a.text.Build, p, append([]buildInstance(nil), p.build.instances...), p.build.loading, p.build.failed}
		})
		select {
		case current = <-reply:
		case <-ctx.Done():
			return result, ctx.Err()
		}
		if err := s.actionWorkspaceCheck(editor)(); err != nil {
			return result, err
		}
		if current.project == nil {
			return result, configfile.ErrConflict
		}
		if !current.loading {
			break
		}
		select {
		case <-timer.C:
		case <-ctx.Done():
			return result, ctx.Err()
		}
	}
	if current.failure != "" {
		return result, errors.New(current.failure)
	}
	if plan.LanguageID != "" {
		if _, err := s.app.waitReadyPluginServer(ctx, current.project, plan.PluginID, plan.LanguageID); err != nil {
			return result, err
		}
	}
	for _, instance := range current.instances {
		if instance.PluginID != plan.PluginID || instance.BuildSystemID != plan.BuildSystemID {
			continue
		}
		execution, err := s.app.resolveBuildExecutable(ctx, current.project, instance, current.messages)
		if err != nil {
			return result, err
		}
		var model core.BuildModel
		if instance.System.Provider {
			model, err = s.app.providerModel(ctx, current.project, instance, s.app.kernel, refresh, execution)
		} else {
			model, err = s.app.commandModel(ctx, current.project, instance, s.app.kernel, current.messages, execution)
		}
		if err != nil {
			return result, err
		}
		result.Builds = append(result.Builds, sourceEditorBuild{instance.Root, instance.Options, core.BuildTool{Executable: execution.Executable}, sourceEditorProjectModel{Projects: model.Projects}})
	}
	return result, nil
}
