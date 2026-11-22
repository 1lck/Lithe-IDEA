package pluginservice

import (
	"context"
	"encoding/json"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginbackend"
)

// LanguageConfigurationResult distinguishes a server without a declared
// template from configuration retained until initialization or sent now.
type LanguageConfigurationResult struct {
	Available bool
	Sent      bool
}

// ApplyLanguageSettings rereads real sources for the exact running declaration.
// Core expands values and updates its existing session; no process is started.
// The caller owns admission, session generation and user-visible error handling.
func (s *Service) ApplyLanguageSettings(ctx context.Context, session *LanguageSession) (LanguageConfigurationResult, error) {
	if session == nil {
		return LanguageConfigurationResult{}, pluginbackend.ErrNoSession
	}
	ctx = core.WithoutRemoteWorkspace(ctx)
	settings, err := s.ReadWorkspacePluginSettings(ctx, session.manifest, session.workspace, session.remote)
	if err != nil {
		return LanguageConfigurationResult{}, err
	}
	configuration, err := s.kernel.ExpandPluginWorkspaceConfiguration(ctx, session.manifest, session.LanguageID, settings.Settings, settings.ProjectSettings)
	if err != nil {
		return LanguageConfigurationResult{}, err
	}
	if configuration == nil {
		return LanguageConfigurationResult{}, nil
	}
	if session.remote != nil && !session.remote.IsCurrent() {
		return LanguageConfigurationResult{}, workspaceSettingsConnectionChanged()
	}
	sent, err := s.kernel.UpdatePluginWorkspaceConfiguration(ctx, session.Session.ID, configuration)
	return LanguageConfigurationResult{Available: true, Sent: sent}, err
}

// ReadWorkspacePluginSettings combines the user's preferences on this
// computer with the project layer read from the selected workspace host.
func (s *Service) ReadWorkspacePluginSettings(ctx context.Context, manifest json.RawMessage, workspace string, remote *core.RemoteWorkspaceConnection) (core.PluginSettingsState, error) {
	if remote == nil {
		snapshot, err := s.Settings.Load(ctx, manifest, workspace)
		return snapshot.State, err
	}
	if !remote.IsCurrent() {
		return core.PluginSettingsState{}, workspaceSettingsConnectionChanged()
	}
	settings, err := s.Settings.LoadRemote(core.WithoutRemoteWorkspace(ctx), manifest, func(ctx context.Context, path string, maximumBytes int64) (*string, error) {
		return s.kernel.ReadWorkspaceConfiguration(remote.Context(ctx), path, maximumBytes)
	})
	if err == nil && !remote.IsCurrent() {
		return core.PluginSettingsState{}, workspaceSettingsConnectionChanged()
	}
	return settings, err
}

func workspaceSettingsConnectionChanged() error {
	return &core.Error{Code: core.CodeConnectionClosed, Message: "The workspace connection changed."}
}
