package pluginservice

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// viewCallTimeout bounds one call of a view function. The contract gives every view event
// 2 seconds; a slower answer fails the event, and the host keeps drawing the last view.
const viewCallTimeout = 2 * time.Second

// ErrViewNotActivating is a view event for a stopped backend whose manifest does not start it
// for the view: a tool window without onView:<window ID>.
var ErrViewNotActivating = errors.New("the plugin's view does not start its backend")

// ViewCall is one event of a plugin view (API-13) for its backend view function.
type ViewCall struct {
	PluginID string
	// Manifest is the installed manifest, which Core checks the result against.
	Manifest json.RawMessage
	// Function is the declared view function: a tool window's view.function or a settings
	// region's view.function.
	Function string
	Surface  core.PluginViewSurface
	// Activation starts a stopped backend when its manifest declares it; empty starts the
	// backend unconditionally, as a settings region's page does.
	Activation string
	// Workspace is the root of the workspace the view is shown for; empty outside one.
	Workspace string
	// Event is the view event's params as the contract names them, without surface, which
	// CallView adds. A settings page puts its own settings in, the saved values with its
	// draft; without them CallView reads the saved values for Workspace, with an empty
	// draft, as a tool window sends them.
	Event json.RawMessage
	// View is the whole view the host drew last; nil before the first result.
	View json.RawMessage
	// Close is a close event: it reaches a running backend only, and its result is ignored.
	Close bool
}

// CallView sends one view event to the plugin's backend and has Core check the answer
// (plugins.ui.applyResult). It returns the whole view to draw and whether it differs from
// call.View; a close event returns neither. A refused answer is a *core.MarketplaceRejection
// with plugin.ui.invalidView, which leaves the caller drawing call.View. ctx cancels the call:
// the host cancels a pending event when the view closes, so its late answer is dropped.
func (s *Service) CallView(ctx context.Context, call ViewCall) (json.RawMessage, bool, error) {
	if s == nil || s.Host == nil || s.kernel == nil {
		return nil, false, ErrBackendUnavailable
	}
	if !validFunctionID(call.Function) {
		return nil, false, errors.New("invalid view function")
	}
	session := s.Host.Running(call.PluginID)
	if session == nil {
		if call.Close {
			return nil, false, nil
		}
		if !declaresBackend(call.Manifest) || (call.Activation != "" && !declaredActivation(call.Manifest, call.Activation)) {
			return nil, false, ErrViewNotActivating
		}
		var err error
		if session, err = s.Host.EnsureBackend(ctx, call.PluginID); err != nil {
			return nil, false, err
		}
	}
	var reference json.RawMessage
	contextID := ""
	if workspace, ok := s.Contexts.ByPath(call.Workspace); ok && call.Workspace != "" {
		reference = mustMarshal(workspace.ContextRef)
		contextID = workspace.ContextID
	}
	var identity struct {
		Instance string `json:"instance"`
	}
	if err := json.Unmarshal(call.Event, &identity); err != nil {
		return nil, false, err
	}
	s.bindView(call.PluginID, session.Session.ID, contextID, identity.Instance)
	event, err := s.viewEvent(ctx, call)
	if err != nil {
		return nil, false, err
	}
	answer, err := session.Call(ctx, call.Function, event, reference, viewCallTimeout)
	if err != nil || call.Close {
		return nil, false, err
	}
	if len(answer) == 0 || string(answer) == "null" {
		answer = json.RawMessage(`{}`)
	}
	return s.kernel.ApplyPluginViewResult(ctx, call.Manifest, call.Surface, call.View, answer)
}

// ViewSettings are the plugin's setting values by ID that a view event carries: Effective is
// what is saved and in force, Draft what the open settings window changed and did not apply.
type ViewSettings struct {
	Effective map[string]json.RawMessage `json:"effective"`
	Draft     map[string]json.RawMessage `json:"draft"`
}

// viewEvent is the event's params with the surface added, and the saved settings when the
// event carries none. A close event, which must reach the backend even when the settings
// cannot be read, goes without them then.
func (s *Service) viewEvent(ctx context.Context, call ViewCall) (json.RawMessage, error) {
	params := map[string]json.RawMessage{}
	if len(call.Event) > 0 {
		if err := json.Unmarshal(call.Event, &params); err != nil {
			return nil, err
		}
	}
	params["surface"] = mustMarshal(call.Surface)
	if _, ok := params["settings"]; !ok {
		effective, err := s.effectiveSettings(ctx, call.Manifest, call.Workspace)
		if err != nil && !call.Close {
			return nil, err
		}
		if effective != nil {
			params["settings"] = mustMarshal(ViewSettings{Effective: effective, Draft: map[string]json.RawMessage{}})
		}
	}
	return json.Marshal(params)
}

// effectiveSettings are the plugin's saved values in force in workspace, by setting ID, as
// Core projects them; a plugin without settings has none.
func (s *Service) effectiveSettings(ctx context.Context, manifest json.RawMessage, workspace string) (map[string]json.RawMessage, error) {
	effective := map[string]json.RawMessage{}
	if s.Settings == nil {
		return effective, nil
	}
	snapshot, err := s.Settings.Load(ctx, manifest, workspace)
	if err != nil {
		return nil, err
	}
	for _, row := range snapshot.State.Rows {
		effective[row.Declaration.ID] = row.Effective.Value
	}
	return effective, nil
}

// ToolWindowViewCall is the call of a tool window's view for one event: the window's backend
// starts for it when its manifest declares onView:<window ID>.
func ToolWindowViewCall(window ToolWindow, workspace string, event, view json.RawMessage, closing bool) ViewCall {
	return ViewCall{
		PluginID: window.PluginID, Manifest: window.Manifest, Function: window.View,
		Surface:    core.PluginViewSurface{ToolWindowID: window.ID},
		Activation: "onView:" + window.ID, Workspace: workspace, Event: event, View: view, Close: closing,
	}
}

// SettingsViewCall is the call of a settings region's view for one event. The region's page
// opening starts the backend, so no activation event is needed.
func SettingsViewCall(editor SettingsEditor, regionID, function, workspace string, event, view json.RawMessage, closing bool) ViewCall {
	return ViewCall{
		PluginID: editor.entry.Installed.ID, Manifest: editor.manifest, Function: function,
		Surface:   core.PluginViewSurface{SettingRegionID: regionID},
		Workspace: workspace, Event: event, View: view, Close: closing,
	}
}
