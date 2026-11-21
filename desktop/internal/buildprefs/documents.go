// Package buildprefs reads the team's and user's build preference documents.
package buildprefs

import (
	"context"
	"encoding/json"
	"errors"

	"github.com/1lck/Lithe-IDEA/desktop/internal/configfile"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

const (
	// TeamFile is relative to the workspace root.
	TeamFile = ".lithe/build/options.json"
	// LocalFile is stored in the app's data directory, keyed by workspace root.
	LocalFile                = "build-local-options.json"
	buildOptionsMaximumBytes = 1 << 20
)

var (
	emptyTeam = json.RawMessage(`{"version":1,"systems":{}}`)
	// EmptyLocal is the default for a workspace without local preferences.
	EmptyLocal = json.RawMessage(`{"version":1,"document":{"version":1,"systems":{}}}`)
)

// Documents are passed to Core for validation and resolution.
type Documents struct {
	Team, Local json.RawMessage
}

// Read reads the team document from the project and the local document from the data
// store. A document that exists but is not valid JSON is an error, not an empty document.
func Read(ctx context.Context, preferences *store.Store, root string) (Documents, error) {
	docs := Documents{Team: emptyTeam, Local: EmptyLocal}
	snapshot, err := configfile.Capture(ctx, root, TeamFile, buildOptionsMaximumBytes)
	if err != nil {
		return docs, err
	}
	if snapshot.Exists() {
		team := snapshot.Bytes()
		if !json.Valid(team) {
			return docs, errors.New(TeamFile + ": invalid JSON")
		}
		docs.Team = team
	}
	if preferences == nil {
		return docs, nil
	}
	all := map[string]json.RawMessage{}
	found, err := preferences.Load(LocalFile, &all)
	if err != nil {
		return docs, err
	}
	if found {
		if local, ok := all[root]; ok && len(local) > 0 {
			docs.Local = local
		}
	}
	return docs, nil
}
