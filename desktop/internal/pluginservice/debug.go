package pluginservice

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"

	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginmanager"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginpkg"
)

// DebugPlugin is one enabled plugin's debug-adapter declaration catalog.
// Core validates the manifest; this is only the presentation and launch data
// the host needs to start the declared adapter process.
type DebugPlugin struct {
	PluginID  string
	Version   string
	Directory string
	Manifest  json.RawMessage
	Adapters  []DebugAdapterDeclaration
}

// DebugAdapterDeclaration is the subset of one `debugAdapters` entry the host
// uses to start a stdio adapter and present it. Adapter behaviour stays in
// Core; the host never interprets DAP payloads.
type DebugAdapterDeclaration struct {
	ID          string
	DisplayName string
	AdapterID   string
	Transport   string
	// LaunchKind is used only to show transports this client can start. It is
	// empty for a tcpLanguageServer adapter, which has no process of its own.
	LaunchKind string
	// Requests are the DAP requests the adapter serves: "launch" and/or "attach".
	Requests []string
	// ConfigurationTypes are the imported launch.json types the adapter answers to.
	ConfigurationTypes []string
	// Endpoint names the language server and command a tcpLanguageServer adapter
	// asks for its loopback port.
	Endpoint DebugAdapterEndpoint
	// AcceptsConnection is true when the attach configuration binds a remote
	// host and port, so the host may offer the host-and-port form.
	AcceptsConnection bool
}

// DebugAdapterEndpoint is the `launch.endpoint` of a tcpLanguageServer adapter.
type DebugAdapterEndpoint struct {
	LanguageID string
	Command    string
}

// Serves reports whether the adapter serves a DAP request. An adapter that names
// no request serves launch, as the contract defaults.
func (d DebugAdapterDeclaration) Serves(request string) bool {
	if len(d.Requests) == 0 {
		return request == "launch"
	}
	for _, served := range d.Requests {
		if served == request {
			return true
		}
	}
	return false
}

// DebugPlugins reads the newest enabled version of every plugin that declares
// debug adapters.
func (s *Service) DebugPlugins(ctx context.Context, entries []pluginmanager.Entry) ([]DebugPlugin, error) {
	var plugins []DebugPlugin
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
		adapters, err := parseDebugAdapters(manifest)
		if err != nil {
			failures = append(failures, fmt.Errorf("%s: %w", entry.Installed.ID, err))
			continue
		}
		if len(adapters) == 0 {
			continue
		}
		plugins = append(plugins, DebugPlugin{
			PluginID:  entry.Installed.ID,
			Version:   entry.Installed.Version,
			Directory: entry.Installed.Path,
			Manifest:  manifest,
			Adapters:  adapters,
		})
	}
	return plugins, errors.Join(failures...)
}

type rawDebugManifest struct {
	DebugAdapters []struct {
		ID                 string   `json:"id"`
		DisplayName        string   `json:"displayName"`
		AdapterID          string   `json:"adapterID"`
		Requests           []string `json:"requests"`
		ConfigurationTypes []string `json:"configurationTypes"`
		Configurations     struct {
			Attach *struct {
				TargetBindings struct {
					Connection json.RawMessage `json:"connection"`
				} `json:"targetBindings"`
			} `json:"attach"`
		} `json:"configurations"`
		Launch struct {
			Transport string `json:"transport"`
			Endpoint  *struct {
				LanguageID string `json:"languageID"`
				Command    string `json:"command"`
			} `json:"endpoint"`
			Process *struct {
				Launch struct {
					Kind string `json:"kind"`
				} `json:"launch"`
			} `json:"process"`
		} `json:"launch"`
	} `json:"debugAdapters"`
}

func parseDebugAdapters(manifest json.RawMessage) ([]DebugAdapterDeclaration, error) {
	var decoded rawDebugManifest
	if err := json.Unmarshal(manifest, &decoded); err != nil {
		return nil, fmt.Errorf("%w: %w", ErrPackageRead, err)
	}
	adapters := make([]DebugAdapterDeclaration, 0, len(decoded.DebugAdapters))
	for _, raw := range decoded.DebugAdapters {
		hosted := raw.Launch.Process == nil && raw.Launch.Transport == "tcpLanguageServer" && raw.Launch.Endpoint != nil
		if raw.ID == "" || (raw.Launch.Process == nil && !hosted) {
			continue
		}
		declaration := DebugAdapterDeclaration{
			ID:                 raw.ID,
			DisplayName:        raw.DisplayName,
			AdapterID:          raw.AdapterID,
			Transport:          raw.Launch.Transport,
			Requests:           raw.Requests,
			ConfigurationTypes: raw.ConfigurationTypes,
			AcceptsConnection:  raw.Configurations.Attach != nil && len(raw.Configurations.Attach.TargetBindings.Connection) > 0,
		}
		if raw.Launch.Process != nil {
			declaration.LaunchKind = raw.Launch.Process.Launch.Kind
		}
		if hosted {
			declaration.Endpoint = DebugAdapterEndpoint{LanguageID: raw.Launch.Endpoint.LanguageID, Command: raw.Launch.Endpoint.Command}
		}
		if declaration.AdapterID == "" {
			declaration.AdapterID = declaration.ID
		}
		adapters = append(adapters, declaration)
	}
	return adapters, nil
}
