package pluginservice

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginbackend"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginlsp"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginmanager"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginpkg"
)

// BackendRequest is the workspace a language server serves.
type BackendRequest struct {
	// RootURI and WorkingDirectory are the workspace root.
	RootURI          any
	WorkingDirectory string
	// Architecture is the platform architecture Core plans for.
	Architecture string
}

// LanguageSession is one running language server.
type LanguageSession struct {
	// PluginID and Version identify the package that is running.
	PluginID string
	Version  string
	// LanguageID identifies the exact declaration used by this session.
	LanguageID string
	// Warnings preserves partial discovery failures for the owning log boundary.
	Warnings  error
	manifest  json.RawMessage
	workspace string
	// Session is Core's session.
	Session pluginbackend.Session
	// Documents keeps the session's open documents in step with the editor.
	Documents *pluginlsp.Tracker
	// ContextID and ContextGeneration name the workspace context the server was
	// started for. A plugin backend reaches the server through them.
	ContextID         string
	ContextGeneration uint64
	// Generation is raised each time the server starts for the context, so a
	// backend can tell which process a state or a notification belongs to.
	Generation uint64
	// temporary is the scratch directory of one backend-resolved start; it is
	// removed when the process ends.
	temporary string
	languageSessionState
}

// StartLanguageServer starts the language server of the plugin that serves
// languageID, if an enabled plugin declares one.
//
// It returns a nil session and no error when nothing serves the language: that is
// the ordinary case for most files, not a failure.
func (s *Service) StartLanguageServer(ctx context.Context, entries []pluginmanager.Entry, languageID string, request BackendRequest) (*LanguageSession, error) {
	entry, ok, err := s.LanguageServerProvider(ctx, entries, languageID)
	if !ok {
		return nil, err
	}
	manifest, readErr := readBounded(filepath.Join(entry.Installed.Path, pluginpkg.ManifestFile), MaxManifestBytes)
	if readErr != nil {
		return nil, errors.Join(err, readErr)
	}
	var workspaceContext WorkspaceContext
	if request.WorkingDirectory != "" && s.Contexts != nil {
		// The server serves this workspace, so a backend that asks for it by
		// context finds it: the context exists for as long as the project is open.
		workspaceContext = s.Contexts.Open(request.WorkingDirectory)
	}
	settings, settingsErr := s.Settings.Load(ctx, manifest, request.WorkingDirectory)
	if settingsErr != nil {
		return nil, errors.Join(err, settingsErr)
	}
	// State lives beside the installed versions, never inside one: an installed
	// package is read-only for the host, and a version directory that changed
	// would no longer match the digest the user approved.
	stateDirectory := filepath.Join(s.Root, pluginStateDirectory, entry.Installed.ID, entry.Installed.Version)
	if stateErr := os.MkdirAll(stateDirectory, 0o700); stateErr != nil {
		return nil, errors.Join(err, stateErr)
	}
	start := pluginbackend.StartRequest{
		Manifest:         manifest,
		PackageDirectory: entry.Installed.Path,
		PluginID:         entry.Installed.ID,
		ProviderID:       entry.Installed.ID + "/language-server",
		LanguageID:       languageID,
		StateDirectory:   stateDirectory,
		Architecture:     request.Architecture,
		Settings:         settings.State.Settings,
		ProjectSettings:  settings.State.ProjectSettings,
		RootURI:          request.RootURI,
		WorkingDirectory: request.WorkingDirectory,
	}
	temporary := ""
	if declaresBackendLaunch(manifest, languageID) {
		resolved, resolveErr := s.resolveBackendLaunch(ctx, entry.Installed.ID, entry.Installed.Version, manifest, languageID, workspaceContext, start)
		if resolveErr != nil {
			return nil, errors.Join(err, resolveErr)
		}
		start.Plan = resolved.plan
		start.LogDirectory = resolved.directories.log
		start.WorkspaceStateDirectory = resolved.directories.workspaceState
		temporary = resolved.directories.temporary
	}
	started, startErr := s.Backend.Start(ctx, start)
	if startErr != nil {
		removeTemporary(temporary)
		return nil, errors.Join(err, startErr)
	}
	session := &LanguageSession{
		PluginID:          entry.Installed.ID,
		Version:           entry.Installed.Version,
		LanguageID:        languageID,
		Warnings:          err,
		manifest:          append(json.RawMessage(nil), manifest...),
		workspace:         request.WorkingDirectory,
		Session:           started,
		Documents:         pluginlsp.New(s.kernel, started.ID),
		ContextID:         workspaceContext.ContextID,
		ContextGeneration: workspaceContext.Generation,
		temporary:         temporary,
	}
	s.registerLanguageSession(session)
	return session, nil
}

// ServeLanguageSession answers the session's host requests until it ends or ctx is
// done, passing every other event to observe, which may be nil.
func (s *Service) ServeLanguageSession(ctx context.Context, session *LanguageSession, observe pluginbackend.EventObserver) error {
	if session == nil {
		return nil
	}
	// The service sees the events plugin backends depend on (completions of the
	// requests they forward, lifecycle changes, forwarded notifications) before
	// the window's observer, which keeps owning diagnostics and semantic answers.
	defer session.end()
	return s.Backend.Serve(ctx, session.Session, func(event core.BackendEvent) {
		s.observeLanguage(session, event)
		if observe != nil {
			observe(event)
		}
	})
}

// RequestLanguageSession submits one semantic request to the session and returns
// the operation ID a later requestCompleted event carries.
func (s *Service) RequestLanguageSession(ctx context.Context, session *LanguageSession, request core.PluginSemanticRequest) (string, error) {
	if session == nil {
		return "", pluginbackend.ErrNoSession
	}
	return s.Backend.Request(ctx, session.Session, request)
}

// StopLanguageServer shuts a session down and disposes it.
func (s *Service) StopLanguageServer(ctx context.Context, session *LanguageSession) error {
	if session == nil {
		return nil
	}
	s.unregisterLanguageSession(session)
	session.end()
	s.observeLanguage(session, core.BackendEvent{Type: "stateChanged", State: "stopped"})
	removeTemporary(session.temporary)
	return s.Backend.Stop(ctx, session.Session)
}

// pluginStateDirectory is the reserved directory below the plugin root where
// running servers keep their state. It starts with a dot, so List never reads it
// as an installed plugin.
const pluginStateDirectory = ".state"

type languageServerDeclaration struct {
	LanguageServers []struct {
		LanguageID string `json:"languageID"`
		Launch     struct {
			Kind string `json:"kind"`
		} `json:"launch"`
	} `json:"languageServers"`
}

// declaresBackendLaunch reports whether the plugin's backend resolves the launch
// of the language server for languageID.
func declaresBackendLaunch(manifest json.RawMessage, languageID string) bool {
	var declaration languageServerDeclaration
	if json.Unmarshal(manifest, &declaration) != nil {
		return false
	}
	for _, server := range declaration.LanguageServers {
		if server.LanguageID == languageID {
			return server.Launch.Kind == "backend"
		}
	}
	return false
}

func removeTemporary(directory string) {
	if directory != "" {
		_ = os.RemoveAll(directory)
	}
}

// LanguageServerProvider reports the enabled plugin that serves languageID.
//
// Only the newest installed version of each plugin is considered, which is the
// same rule the language contributions use: installing a version does not remove
// the earlier one, and the older version must not answer for the plugin.
//
// The error summarises plugins whose manifests could not be read; the others are
// still searched, so one broken package does not hide a working provider.
func (s *Service) LanguageServerProvider(ctx context.Context, entries []pluginmanager.Entry, languageID string) (pluginmanager.Entry, bool, error) {
	if s == nil || languageID == "" {
		return pluginmanager.Entry{}, false, nil
	}
	var failures []error
	selected, selectionErr := s.selectInstalled(ctx, entries, false)
	if selectionErr != nil {
		failures = append(failures, selectionErr)
	}
	for _, entry := range selected {
		manifest, err := readBounded(filepath.Join(entry.Installed.Path, pluginpkg.ManifestFile), MaxManifestBytes)
		if err != nil {
			failures = append(failures, fmt.Errorf("%s: %w", entry.Installed.ID, err))
			continue
		}
		var declaration languageServerDeclaration
		if err := json.Unmarshal(manifest, &declaration); err != nil {
			failures = append(failures, fmt.Errorf("%s: %w", entry.Installed.ID, err))
			continue
		}
		for _, server := range declaration.LanguageServers {
			if server.LanguageID == languageID {
				return entry, true, errors.Join(failures...)
			}
		}
	}
	return pluginmanager.Entry{}, false, errors.Join(failures...)
}
