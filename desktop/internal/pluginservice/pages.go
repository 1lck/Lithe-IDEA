package pluginservice

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"time"
)

// Plugin web pages (`ui` 2) reach a plugin's backend and keep a small state
// per tool window and workspace. Core checks every request a page makes
// (plugins.web.request); these are the host's side of the checked requests.

// pageCallTimeout is the deadline Core gives one function call of a page.
const pageCallTimeout = 15 * time.Minute

// ErrPageStateTooLarge is a stored state over the limit Core sets for pages.
var ErrPageStateTooLarge = errors.New("plugin page state is too large")

// CallFromPage invokes a function of the plugin's own backend for the
// workspace at workspacePath, handing its progress to progress.
func (s *Service) CallFromPage(ctx context.Context, pluginID, function string, params json.RawMessage, workspacePath string, progress func(json.RawMessage)) (json.RawMessage, error) {
	workspace, ok := s.Contexts.ByPath(workspacePath)
	if !ok {
		return nil, ErrContextExpired
	}
	reference, err := json.Marshal(workspace.ContextRef)
	if err != nil {
		return nil, err
	}
	return s.Host.CallWithProgress(ctx, pluginID, function, params, reference, pageCallTimeout, progress)
}

// pageStatePath is where one window's page state for one workspace is kept:
// in the plugin's state directory, outside its package and the application
// bundle. The window ID is a digest, so it is one path component.
func (s *Service) pageStatePath(pluginID, windowID, workspacePath string) string {
	sum := sha256.Sum256([]byte(windowID))
	return filepath.Join(s.Root, pluginStateDirectory, pluginID, "pages", "workspaces", WorkspaceKey(workspacePath), hex.EncodeToString(sum[:])[:24]+".json")
}

// PageState returns the stored state of a window, nil when there is none.
// A state over limit bytes is treated as none.
func (s *Service) PageState(pluginID, windowID, workspacePath string, limit int) ([]byte, error) {
	path := s.pageStatePath(pluginID, windowID, workspacePath)
	info, err := os.Stat(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	if info.Size() > int64(limit) {
		return nil, ErrPageStateTooLarge
	}
	return os.ReadFile(path)
}

// SetPageState stores the state of a window, or removes it for nil. It
// writes a temporary file and renames it, so a reader never sees half a state.
func (s *Service) SetPageState(pluginID, windowID, workspacePath string, state []byte, limit int) error {
	path := s.pageStatePath(pluginID, windowID, workspacePath)
	if state == nil {
		if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
		return nil
	}
	if len(state) > limit {
		return ErrPageStateTooLarge
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	temporary, err := os.CreateTemp(filepath.Dir(path), ".state-*")
	if err != nil {
		return err
	}
	defer os.Remove(temporary.Name())
	if _, err := temporary.Write(state); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	return os.Rename(temporary.Name(), path)
}
