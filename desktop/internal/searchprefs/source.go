// Package searchprefs owns the native source of application-wide search preferences.
// Only explicit Apply writes this source, outside installed application resources.
package searchprefs

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"reflect"

	"github.com/1lck/Lithe-IDEA/desktop/internal/configfile"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

const relativePath = "search.json"
const maximumSourceBytes = 64 << 10

// Snapshot binds editable preferences to the exact native source read by the page.
type Snapshot struct {
	Stored    core.StoredSearchPreferences
	Effective core.SearchPreferences
	Path      string
	source    configfile.Snapshot
}

// Source resolves its location from platform application storage, never an app bundle.
type Source struct{ Root string }

func (s Source) Load(ctx context.Context) (Snapshot, error) {
	file, err := configfile.Capture(ctx, s.Root, relativePath, maximumSourceBytes)
	if err != nil {
		return Snapshot{}, err
	}
	result := Snapshot{source: file, Path: file.Path()}
	if file.Exists() {
		if !bytes.HasPrefix(bytes.TrimSpace(file.Bytes()), []byte("{")) {
			return Snapshot{}, errors.New("invalid search preference document")
		}
		if err = json.Unmarshal(file.Bytes(), &result.Stored); err != nil {
			return Snapshot{}, err
		}
	}
	result.Effective, err = core.NewClient().ResolveSearchPreferences(ctx, result.Stored.MaxFileBytes, result.Stored.ReplacementMaxFileBytes)
	return result, err
}

// Save preserves unrelated keys, rejects external changes and returns a fresh read-back.
func (s Source) Save(ctx context.Context, baseline Snapshot, stored core.StoredSearchPreferences) (Snapshot, error) {
	if _, err := core.NewClient().ResolveSearchPreferences(ctx, stored.MaxFileBytes, stored.ReplacementMaxFileBytes); err != nil {
		return Snapshot{}, err
	}
	if err := baseline.source.Verify(ctx); err != nil {
		return Snapshot{}, err
	}
	if reflect.DeepEqual(baseline.Stored, stored) {
		return s.Load(ctx)
	}
	fields := map[string]json.RawMessage{}
	if baseline.source.Exists() {
		if err := json.Unmarshal(baseline.source.Bytes(), &fields); err != nil {
			return Snapshot{}, err
		}
	}
	for key, value := range map[string]*uint64{"maxFileBytes": stored.MaxFileBytes, "replacementMaxFileBytes": stored.ReplacementMaxFileBytes} {
		if value == nil {
			delete(fields, key)
		} else {
			encoded, err := json.Marshal(*value)
			if err != nil {
				return Snapshot{}, err
			}
			fields[key] = encoded
		}
	}
	data, err := json.MarshalIndent(fields, "", "  ")
	if err != nil {
		return Snapshot{}, err
	}
	if _, err = baseline.source.Replace(ctx, append(data, '\n'), nil); err != nil {
		return Snapshot{}, err
	}
	result, err := s.Load(ctx)
	if err == nil && !reflect.DeepEqual(result.Stored, stored) {
		err = errors.New("search preferences changed during read-back")
	}
	return result, err
}
