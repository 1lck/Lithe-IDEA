package pluginservice

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginbackend"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginlsp"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginmanager"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginpkg"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginruntime"
)

// BackendRequest is the workspace a language server serves.
type BackendRequest struct {
	// RootURI and WorkingDirectory are the workspace root.
	RootURI          any
	WorkingDirectory string
	// Context is captured while the window owns WorkingDirectory. A background
	// start cannot adopt a new context after the same path is reopened.
	Context ContextRef
	// Architecture is the platform architecture Core plans for.
	Architecture string
	// ProjectCodeAllowed is whether the user trusts the workspace. Without it Core plans no
	// language server that would run project code, and the start fails with
	// core.LaunchUntrustedWorkspace.
	ProjectCodeAllowed bool
	// RuntimeProgress reports cancellable preparation before the bounded server
	// launch. It may be called from a worker goroutine.
	RuntimeProgress func(pluginruntime.Progress)
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
	// launch is set when the backend's launch answer carried the server's
	// workspace configuration; an immediate setting change asks it again.
	launch *launchConfiguration
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
	ctx, preparation, preparationErr := s.beginRuntimePreparation(ctx, entry.Installed.ID)
	if preparationErr != nil {
		return nil, errors.Join(err, preparationErr)
	}
	var cleanupErr error
	defer func() { preparation.finish(cleanupErr) }()
	// The start is one attempt of the plugin's languageServers declaration. What fails before
	// the runner hands it to Core is the host's to record, as a launch it could not resolve;
	// Core records everything after the handoff.
	attempt := core.StartPluginAttempt(entry.Installed.ID, core.OperationLanguageServerStart, core.OriginOf(ctx).Operation)
	fail := func(cause error) (*LanguageSession, error) {
		s.EndAttempt(ctx, attempt, core.StageResolve, cause)
		return nil, errors.Join(err, cause)
	}
	manifest, readErr := readBounded(filepath.Join(entry.Installed.Path, pluginpkg.ManifestFile), MaxManifestBytes)
	if readErr != nil {
		return fail(readErr)
	}
	workspaceContext, contextErr := s.workspaceForBackend(ctx, request)
	if contextErr != nil {
		return fail(contextErr)
	}
	settings, settingsErr := s.Settings.Load(ctx, manifest, request.WorkingDirectory)
	if settingsErr != nil {
		return fail(settingsErr)
	}
	runtimes, runtimeErr := s.EnsureRuntimesWithSettings(ctx, manifest, entry.Installed.Path, entry.Installed.ID, entry.Installed.Version, false, settings.State, request.RuntimeProgress)
	if runtimeErr != nil {
		return fail(runtimeErr)
	}
	if _, contextErr := s.workspaceForBackend(ctx, request); contextErr != nil {
		return fail(contextErr)
	}
	// Downloads have their own cancellation and transport stall limits. Apply
	// the process-start budget only after the environment is ready, so slow
	// healthy downloads do not repeatedly lose their progress.
	ctx, cancelStart := context.WithTimeout(ctx, 2*time.Minute)
	defer cancelStart()
	// State lives beside the installed versions, never inside one: an installed
	// package is read-only for the host, and a version directory that changed
	// would no longer match the digest the user approved.
	stateDirectory := pluginpkg.VersionStateRoot(s.Root, entry.Installed.ID, entry.Installed.Version)
	if stateErr := os.MkdirAll(stateDirectory, 0o700); stateErr != nil {
		return fail(stateErr)
	}
	start := pluginbackend.StartRequest{
		Manifest:           manifest,
		PackageDirectory:   entry.Installed.Path,
		PluginID:           entry.Installed.ID,
		ProviderID:         entry.Installed.ID + "/language-server",
		LanguageID:         languageID,
		Attempt:            attempt,
		StateDirectory:     stateDirectory,
		LogDirectory:       s.logDirectory(ctx, entry.Installed.ID),
		Architecture:       request.Architecture,
		Settings:           settings.State.Settings,
		ProjectSettings:    settings.State.ProjectSettings,
		RootURI:            request.RootURI,
		WorkingDirectory:   request.WorkingDirectory,
		ManagedTools:       runtimes.Tools,
		ProjectCodeAllowed: request.ProjectCodeAllowed,
	}
	temporary := ""
	var launch *launchConfiguration
	if declaresBackendLaunch(manifest, languageID) {
		resolved, resolveErr := s.resolveBackendLaunch(ctx, entry.Installed.ID, entry.Installed.Version, manifest, languageID, workspaceContext, start, runtimes)
		if resolveErr != nil {
			return fail(resolveErr)
		}
		start.Plan = resolved.plan
		start.WorkspaceStateDirectory = resolved.directories.workspaceState
		temporary = resolved.directories.temporary
		launch = resolved.configuration
	}
	if _, contextErr := s.workspaceForBackend(ctx, request); contextErr != nil {
		removeTemporary(temporary)
		return fail(contextErr)
	}
	started, startErr := s.Backend.Start(ctx, start)
	if startErr != nil {
		removeTemporary(temporary)
		return fail(startErr)
	}
	if _, contextErr := s.workspaceForBackend(ctx, request); contextErr != nil {
		preparation.retryCleanup = func(stopCtx context.Context) error {
			disposed, err := s.Backend.StopAndDispose(stopCtx, started)
			if disposed {
				removeTemporary(temporary)
			}
			return s.runtimeStopFailure(stopCtx, disposed, err)
		}
		stopCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), backendStopTimeout)
		cleanupErr = preparation.retryCleanup(stopCtx)
		cancel()
		return fail(errors.Join(contextErr, cleanupErr))
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
		launch:            launch,
	}
	s.registerLanguageSession(session)
	return session, nil
}

func (s *Service) workspaceForBackend(ctx context.Context, request BackendRequest) (WorkspaceContext, error) {
	if err := ctx.Err(); err != nil {
		return WorkspaceContext{}, err
	}
	if request.WorkingDirectory == "" {
		return WorkspaceContext{}, nil
	}
	workspace, err := s.checkedWorkspaceContext(ctx, request.Context)
	if err != nil {
		return WorkspaceContext{}, err
	}
	if filepath.Clean(workspace.Path) != filepath.Clean(request.WorkingDirectory) {
		return WorkspaceContext{}, ErrContextExpired
	}
	return workspace, nil
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
	session.end()
	s.observeLanguage(session, core.BackendEvent{Type: "stateChanged", State: "stopped"})
	disposed, err := s.Backend.StopAndDispose(ctx, session.Session)
	if disposed {
		s.unregisterLanguageSession(session)
		removeTemporary(session.temporary)
	}
	return err
}

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
