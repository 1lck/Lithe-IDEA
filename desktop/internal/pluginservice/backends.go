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
	started, startErr := s.Backend.Start(ctx, pluginbackend.StartRequest{
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
	})
	if startErr != nil {
		return nil, errors.Join(err, startErr)
	}
	return &LanguageSession{
		PluginID:   entry.Installed.ID,
		Version:    entry.Installed.Version,
		LanguageID: languageID,
		Warnings:   err,
		manifest:   append(json.RawMessage(nil), manifest...),
		workspace:  request.WorkingDirectory,
		Session:    started,
		Documents:  pluginlsp.New(s.kernel, started.ID),
	}, nil
}

// ServeLanguageSession answers the session's host requests until it ends or ctx is
// done, passing every other event to observe, which may be nil.
func (s *Service) ServeLanguageSession(ctx context.Context, session *LanguageSession, observe pluginbackend.EventObserver) error {
	if session == nil {
		return nil
	}
	return s.Backend.Serve(ctx, session.Session, observe)
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
	return s.Backend.Stop(ctx, session.Session)
}

// pluginStateDirectory is the reserved directory below the plugin root where
// running servers keep their state. It starts with a dot, so List never reads it
// as an installed plugin.
const pluginStateDirectory = ".state"

type languageServerDeclaration struct {
	LanguageServers []struct {
		LanguageID string `json:"languageID"`
	} `json:"languageServers"`
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
