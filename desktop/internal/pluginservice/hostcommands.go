package pluginservice

import (
	"context"
	"encoding/json"
	"errors"
	"path/filepath"

	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginpkg"
)

// notifyCommandDidRun is lithe/host/commands/didRun, which every plugin-owned
// session may receive.
const notifyCommandDidRun = "lithe/host/commands/didRun"

// ErrCommandNotActivating reports a command of a stopped backend that did not
// declare onCommand:<commandID>, so running it must not start the backend.
var ErrCommandNotActivating = errors.New("the plugin's backend is stopped and does not activate on this command")

// NotifyCommandRun tells a plugin's backend that the user ran one of its
// commands. The notification is an event, not an acknowledgement that the
// command's work succeeded. A running backend receives it in order with the
// other notifications; a stopped one is started only when its manifest declares
// onCommand:<commandID>, and receives it once it is ready. workspaceRoot names
// the window's workspace and may be empty.
func (s *Service) NotifyCommandRun(ctx context.Context, pluginID, commandID, workspaceRoot string) error {
	if s == nil || s.Host == nil {
		return ErrBackendUnavailable
	}
	if !validFunctionID(commandID) {
		return errors.New("invalid command ID")
	}
	session := s.Host.Running(pluginID)
	if session == nil {
		manifest, err := s.installedManifest(ctx, pluginID)
		if err != nil {
			return err
		}
		if !declaresBackend(manifest) || !declaredActivation(manifest, "onCommand:"+commandID) {
			return ErrCommandNotActivating
		}
		if session, err = s.Host.EnsureBackend(ctx, pluginID); err != nil {
			return err
		}
	}
	if err := session.waitFor(ctx, func() bool { return session.ready }); err != nil {
		return err
	}
	params := map[string]any{"commandID": commandID}
	if workspace, ok := s.Contexts.ByPath(workspaceRoot); ok && workspaceRoot != "" {
		params["context"] = workspace.ContextRef
	}
	encoded, err := json.Marshal(params)
	if err != nil {
		return err
	}
	_, err = s.kernel.SendPluginHostNotification(ctx, session.Session.ID, notifyCommandDidRun, encoded)
	return err
}

// installedManifest reads the manifest of the selected installed version.
func (s *Service) installedManifest(ctx context.Context, pluginID string) (json.RawMessage, error) {
	entries, err := s.Manager.Installed()
	if err != nil {
		return nil, err
	}
	selected, selectionErr := s.selectInstalled(ctx, entries, false)
	for _, candidate := range selected {
		if candidate.Installed.ID == pluginID {
			return readBounded(filepath.Join(candidate.Installed.Path, pluginpkg.ManifestFile), MaxManifestBytes)
		}
	}
	return nil, errors.Join(ErrBackendUnavailable, selectionErr)
}
