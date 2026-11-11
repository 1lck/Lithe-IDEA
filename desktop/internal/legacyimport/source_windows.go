package legacyimport

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
)

const (
	// tauriIdentifier is the earlier Windows client's application identifier, the
	// folder its Tauri store lives in under %APPDATA%.
	tauriIdentifier = "app.lithe.windows"
	// maxSettingsBytes bounds the settings file read into memory.
	maxSettingsBytes = 8 << 20
)

// macDomain names the macOS source; unused on Windows but shared by the mapping.
const macDomain = "app.lithe.desktop"

// read reads the Tauri store's settings.json. A missing file is ErrNotFound.
func read(ctx context.Context) (Found, error) {
	if err := ctx.Err(); err != nil {
		return Found{}, err
	}
	base, err := os.UserConfigDir()
	if err != nil {
		return Found{}, err
	}
	path := filepath.Join(base, tauriIdentifier, "settings.json")
	file, err := os.Open(path)
	if errors.Is(err, os.ErrNotExist) {
		return Found{}, ErrNotFound
	}
	if err != nil {
		return Found{}, err
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, maxSettingsBytes+1))
	if err != nil {
		return Found{}, err
	}
	if len(data) > maxSettingsBytes {
		return Found{}, errTooLarge
	}
	var values map[string]json.RawMessage
	if err := json.Unmarshal(data, &values); err != nil {
		return Found{}, err
	}
	found := fromTauriSettings(path, values)
	if found.Empty() {
		return Found{}, ErrNotFound
	}
	return found, nil
}
