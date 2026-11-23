package pluginservice

import (
	"context"
	"encoding/json"

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
// A server whose backend answered its own workspace configuration at launch
// gets it from the backend again, with the new settings, instead of the
// declaration's expansion, which would replace what the backend derived.
// The caller owns admission, session generation and user-visible error handling.
func (s *Service) ApplyLanguageSettings(ctx context.Context, session *LanguageSession) (LanguageConfigurationResult, error) {
	if session == nil {
		return LanguageConfigurationResult{}, pluginbackend.ErrNoSession
	}
	snapshot, err := s.Settings.Load(ctx, session.manifest, session.workspace)
	if err != nil {
		return LanguageConfigurationResult{}, err
	}
	var configuration json.RawMessage
	if session.launch != nil {
		configuration, err = s.launchWorkspaceConfiguration(ctx, *session.launch, snapshot.State.Settings, snapshot.State.ProjectSettings)
	} else {
		configuration, err = s.kernel.ExpandPluginWorkspaceConfiguration(ctx, session.manifest, session.LanguageID, snapshot.State.Settings, snapshot.State.ProjectSettings)
	}
	if err != nil {
		return LanguageConfigurationResult{}, err
	}
	if configuration == nil {
		return LanguageConfigurationResult{}, nil
	}
	sent, err := s.kernel.UpdatePluginWorkspaceConfiguration(ctx, session.Session.ID, configuration)
	return LanguageConfigurationResult{Available: true, Sent: sent}, err
}
