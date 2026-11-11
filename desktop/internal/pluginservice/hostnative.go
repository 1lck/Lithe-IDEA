package pluginservice

import (
	"context"
	"encoding/json"
	"errors"
	"time"
)

// nativeActionTimeout bounds one invoke action of a native panel.
const nativeActionTimeout = 60 * time.Second

// InvokeToolWindowAction calls the function of a native panel's invoke action in the workspace at root,
// with the selected node's ID (or null). The answer may carry a message the panel shows; the rest of it
// belongs to the plugin. The plugin must be running: its panel does not start a backend.
func (s *Service) InvokeToolWindowAction(ctx context.Context, root, pluginID, function, selectedID string, values map[string]any) (string, error) {
	if s == nil {
		return "", ErrBackendUnavailable
	}
	workspace, ok := s.Contexts.ByPath(root)
	if !ok {
		return "", errors.New("the workspace is not open")
	}
	session := s.Host.Running(pluginID)
	if session == nil {
		return "", ErrBackendUnavailable
	}
	if !session.hasFunction(function) {
		return "", errors.New("the action's function is not registered")
	}
	var selected any
	if selectedID != "" {
		selected = selectedID
	}
	argument := map[string]any{"selectedID": selected}
	if values != nil {
		argument["values"] = values
	}
	answer, err := session.Call(ctx, function, mustMarshal(argument), mustMarshal(workspace.ContextRef), nativeActionTimeout)
	if err != nil {
		return "", err
	}
	var result struct {
		Message string `json:"message"`
	}
	if len(answer) > 0 && string(answer) != "null" {
		if err := json.Unmarshal(answer, &result); err != nil {
			return "", err
		}
	}
	return result.Message, nil
}

// InvokeNativeSource calls a source panel's function for the instance it reads and returns the nodes it
// answers with. Core checks the reply against the panel's declaration (declaration is the window's native
// object), so the host applies no rule of its own. The function receives the build system ID and the
// instance's root.
func (s *Service) InvokeNativeSource(ctx context.Context, root, pluginID string, declaration json.RawMessage, function, buildSystemID, instanceRoot string) ([]NativeNode, error) {
	if s == nil {
		return nil, ErrBackendUnavailable
	}
	workspace, ok := s.Contexts.ByPath(root)
	if !ok {
		return nil, errors.New("the workspace is not open")
	}
	session := s.Host.Running(pluginID)
	if session == nil {
		return nil, ErrBackendUnavailable
	}
	if !session.hasFunction(function) {
		return nil, errors.New("the source's function is not registered")
	}
	answer, err := session.Call(ctx, function, mustMarshal(map[string]any{"buildSystemID": buildSystemID, "root": instanceRoot}), mustMarshal(workspace.ContextRef), nativeActionTimeout)
	if err != nil {
		return nil, err
	}
	if s.kernel == nil {
		return nil, ErrBackendUnavailable
	}
	checked, err := s.kernel.ValidatePluginNativeData(ctx, declaration, answer)
	if err != nil {
		return nil, err
	}
	var result struct {
		Nodes []NativeNode `json:"nodes"`
	}
	if err := json.Unmarshal(checked, &result); err != nil {
		return nil, err
	}
	return result.Nodes, nil
}
