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

// InstalledSnapshot owns the manifests read for one operation. Its consumers
// share read-only bytes; discard the snapshot when the operation finishes and
// call ReadInstalled again after installation or enablement changes. It is not
// a service cache. Each file is bounded by MaxManifestBytes.
type InstalledSnapshot struct {
	manifests []installedManifest
}

type installedManifest struct {
	entry    pluginmanager.Entry
	manifest json.RawMessage
}

// ReadInstalled asks Core for the enabled versions once and reads each selected
// manifest once. A non-empty snapshot may accompany errors for other plugins.
// Report these shared errors once at the caller's operation boundary; individual
// consumers report only failures while reading their own contribution sections.
func (s *Service) ReadInstalled(ctx context.Context, entries []pluginmanager.Entry) (InstalledSnapshot, error) {
	return s.readInstalled(ctx, entries, false)
}

func (s *Service) readInstalled(ctx context.Context, entries []pluginmanager.Entry, includeDisabled bool) (InstalledSnapshot, error) {
	if err := ctx.Err(); err != nil {
		return InstalledSnapshot{}, err
	}
	selected, selectionErr := s.selectInstalled(ctx, entries, includeDisabled)
	if err := ctx.Err(); err != nil {
		return InstalledSnapshot{}, errors.Join(selectionErr, err)
	}
	snapshot := InstalledSnapshot{manifests: make([]installedManifest, 0, len(selected))}
	failures := []error{selectionErr}
	for _, entry := range selected {
		if err := ctx.Err(); err != nil {
			return InstalledSnapshot{}, errors.Join(append(failures, err)...)
		}
		manifest, err := readBounded(filepath.Join(entry.Installed.Path, pluginpkg.ManifestFile), MaxManifestBytes)
		if err != nil {
			failures = append(failures, fmt.Errorf("%s: %w", entry.Installed.ID, err))
			continue
		}
		snapshot.manifests = append(snapshot.manifests, installedManifest{entry: entry, manifest: manifest})
	}
	return snapshot, errors.Join(failures...)
}
