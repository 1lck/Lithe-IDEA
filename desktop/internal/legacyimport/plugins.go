package legacyimport

import (
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strings"
)

// Plugin is a plugin the earlier client had installed: its ID, the name its manifest
// gives and the active version. Packages are not copied: the Viva client installs a
// plugin again from the marketplace, which checks it for this host.
type Plugin struct {
	ID, Name, Version string
}

const (
	// maxPlugins bounds the plugins listed from one source.
	maxPlugins = 500
	// maxRecordBytes bounds an installation record or manifest read to find a name.
	maxRecordBytes = 1 << 20
)

// macPlugins lists the earlier macOS client's plugins under root
// (Application Support/Lithe/Plugins): each <id>/installation.json whose package was
// installed, not shipped inside the app, and is not being removed.
func macPlugins(root string) []Plugin {
	return listPlugins(root, func(data []byte) (id, version string, ok bool) {
		var record struct {
			PluginID      json.RawMessage `json:"pluginID"`
			ActiveVersion json.RawMessage `json:"activeVersion"`
			Origin        string          `json:"origin"`
			Status        string          `json:"status"`
		}
		if json.Unmarshal(data, &record) != nil || record.Origin == "bundled" || (record.Status != "installed" && record.Status != "updateStaged") {
			return "", "", false
		}
		id, version = swiftValue(record.PluginID), swiftValue(record.ActiveVersion)
		return id, version, id != ""
	})
}

// windowsPlugins lists the earlier Windows client's plugins under root
// (%LOCALAPPDATA%\app.lithe.windows\plugins).
func windowsPlugins(root string) []Plugin {
	return listPlugins(root, func(data []byte) (id, version string, ok bool) {
		var record struct {
			PluginID string `json:"pluginId"`
			Version  string `json:"version"`
		}
		if json.Unmarshal(data, &record) != nil {
			return "", "", false
		}
		return record.PluginID, record.Version, record.PluginID != ""
	})
}

// swiftValue reads a Swift RawRepresentable or version value, which encodes as a single
// string, or as {"rawValue": "..."} where it does not.
func swiftValue(raw json.RawMessage) string {
	var text string
	if json.Unmarshal(raw, &text) == nil {
		return text
	}
	var wrapped struct {
		RawValue string `json:"rawValue"`
	}
	if json.Unmarshal(raw, &wrapped) == nil {
		return wrapped.RawValue
	}
	return ""
}

func listPlugins(root string, record func([]byte) (id, version string, ok bool)) []Plugin {
	entries, err := os.ReadDir(root)
	if err != nil {
		return nil
	}
	var plugins []Plugin
	for _, entry := range entries {
		if len(plugins) == maxPlugins {
			break
		}
		if !entry.IsDir() || strings.HasPrefix(entry.Name(), ".") {
			continue
		}
		directory := filepath.Join(root, entry.Name())
		data, err := readBounded(filepath.Join(directory, "installation.json"))
		if err != nil {
			continue
		}
		id, version, ok := record(data)
		if !ok || id != entry.Name() {
			continue
		}
		name := id
		if version != "" && filepath.IsLocal(version) {
			if manifest, err := readBounded(filepath.Join(directory, version, "plugin.json")); err == nil {
				var fields struct {
					DisplayName string `json:"displayName"`
				}
				if json.Unmarshal(manifest, &fields) == nil && strings.TrimSpace(fields.DisplayName) != "" {
					name = strings.TrimSpace(fields.DisplayName)
				}
			}
		}
		plugins = append(plugins, Plugin{ID: id, Name: name, Version: version})
	}
	slices.SortFunc(plugins, func(a, b Plugin) int { return strings.Compare(a.ID, b.ID) })
	return plugins
}

// readBounded reads a regular file of at most maxRecordBytes, not following a link.
func readBounded(path string) ([]byte, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() {
		return nil, errors.New("not a regular file")
	}
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, maxRecordBytes+1))
	if err != nil {
		return nil, err
	}
	if len(data) > maxRecordBytes {
		return nil, errTooLarge
	}
	return data, nil
}
