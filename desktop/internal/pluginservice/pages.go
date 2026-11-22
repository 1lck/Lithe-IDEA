package pluginservice

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginhost"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginpkg"
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
	return s.CallFromWorkspace(ctx, pluginID, function, params, workspace.ContextRef, progress)
}

// CallFromWorkspace invokes the local backend for the captured workspace generation.
func (s *Service) CallFromWorkspace(ctx context.Context, pluginID, function string, params json.RawMessage, ref ContextRef, progress func(json.RawMessage)) (json.RawMessage, error) {
	workspace, err := s.Contexts.Lookup(ref)
	if err != nil {
		return nil, err
	}
	var connection *core.RemoteWorkspaceConnection
	if workspace.remote.binding != nil {
		connection = workspace.remote.binding.CaptureConnection()
		if connection == nil {
			return nil, &core.Error{Code: core.CodeConnectionClosed, Message: "The remote workspace is disconnected."}
		}
		bound, cancel := context.WithCancel(ctx)
		defer cancel()
		stopClose := context.AfterFunc(workspace.lifetime, cancel)
		defer stopClose()
		stopDetach := connection.AfterDetach(cancel)
		defer stopDetach()
		ctx = bound
	}
	reference, err := json.Marshal(ref)
	if err != nil {
		return nil, err
	}
	result, err := s.Host.CallWithProgress(core.WithoutRemoteWorkspace(ctx), pluginID, function, params, reference, pageCallTimeout, progress)
	if _, lookupErr := s.Contexts.Lookup(ref); lookupErr != nil {
		return nil, lookupErr
	}
	if connection != nil && !connection.IsCurrent() {
		return nil, &core.Error{Code: core.CodeConnectionClosed, Message: "The remote workspace connection changed."}
	}
	return result, err
}

// PageDocument is a scoped editor read tied to the attachment that answered it.
type PageDocument struct {
	Path       string
	Data       []byte
	Connection *core.RemoteWorkspaceConnection
}

func (s *Service) ReadPageDocument(ctx context.Context, pluginID string, ref ContextRef, path string, limit int64) (PageDocument, *pluginhost.Failure) {
	workspace, err := s.Contexts.Lookup(ref)
	if err != nil {
		return PageDocument{}, contextFailure(err)
	}
	if workspace.remote.binding == nil {
		return PageDocument{}, unsupportedRemoteWorkspace()
	}
	connection := workspace.remote.binding.CaptureConnection()
	if connection == nil {
		return PageDocument{}, failure(CodeRemoteDisconnected, "The remote workspace is disconnected.")
	}
	raw, refusal := s.readRemotePluginFile(ctx, workspace, connection, pluginWorkspaceResource{
		Path: &path, RootID: s.Contexts.RootID(pluginID, workspace.Path),
	}, core.PluginFileOperation{Kind: "openDocument", MaximumBytes: &limit})
	if refusal != nil {
		return PageDocument{}, refusal
	}
	var result struct {
		Path        string `json:"path"`
		Base64      string `json:"base64"`
		IsTruncated bool   `json:"isTruncated"`
	}
	if err := json.Unmarshal(raw, &result); err != nil || result.Path == "" {
		return PageDocument{}, failure(pluginhost.CodeHostFailure, "The host returned an invalid document.")
	}
	if result.IsTruncated {
		return PageDocument{}, failure("plugin.host.limitExceeded", "The document exceeds the editor's read budget.")
	}
	data, err := base64.StdEncoding.DecodeString(result.Base64)
	if err != nil {
		return PageDocument{}, failure(pluginhost.CodeHostFailure, "The host returned an invalid document.")
	}
	return PageDocument{Path: result.Path, Data: data, Connection: connection}, nil
}

// pageStatePath is where one window's page state for one workspace is kept:
// in the plugin's state directory, outside its package and the application
// bundle. The window ID is a digest, so it is one path component.
func (s *Service) pageStatePath(pluginID, windowID string, workspace WorkspaceContext) string {
	sum := sha256.Sum256([]byte(windowID))
	key := WorkspaceKey(workspace.Path)
	if workspace.authorityKind() == "remote" {
		identity := sha256.Sum256([]byte(workspace.remote.connectionID + "\x00" + workspace.remote.hostPath))
		key = "remote-" + hex.EncodeToString(identity[:])[:24]
	}
	return filepath.Join(pluginpkg.StateRoot(s.Root, pluginID), "pages", "workspaces", key, hex.EncodeToString(sum[:])[:24]+".json")
}

// PageState returns the stored state of a window, nil when there is none.
// A state over limit bytes is treated as none.
func (s *Service) PageState(pluginID, windowID string, ref ContextRef, limit int) ([]byte, error) {
	workspace, err := s.Contexts.Lookup(ref)
	if err != nil {
		return nil, err
	}
	path := s.pageStatePath(pluginID, windowID, workspace)
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
func (s *Service) SetPageState(pluginID, windowID string, ref ContextRef, state []byte, limit int) error {
	workspace, err := s.Contexts.Lookup(ref)
	if err != nil {
		return err
	}
	path := s.pageStatePath(pluginID, windowID, workspace)
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
	if _, err := s.Contexts.Lookup(ref); err != nil {
		return err
	}
	return os.Rename(temporary.Name(), path)
}
