package settingswindow

import (
	"context"

	"github.com/1lck/Lithe-IDEA/desktop/internal/configfile"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// ErrFileTypeMappingsConflict reports that a mapping file changed on disk after Load.
var ErrFileTypeMappingsConflict = configfile.ErrConflict

// FileTypeMappingsSnapshot is the global and project file-type mapping configuration shown
// and edited on "Appearance & Behavior › File Type Mappings".
type FileTypeMappingsSnapshot struct {
	HasWorkspace       bool
	WorkspaceRoot      string
	GlobalConfigPath   string
	GlobalFingerprint  string
	ProjectConfigPath  string
	ProjectFingerprint string
	Global             []core.FileTypeMapping
	Project            []core.FileTypeMapping
	Builtins           []core.FileTypeMapping
	KnownLanguageIDs   []string

	// GlobalSource and ProjectSource hold the bounded native snapshots captured on Load for
	// conflict-checked atomic updates.
	GlobalSource  configfile.Snapshot
	ProjectSource configfile.Snapshot
}

// FileTypeMappingsSaveResult returns the freshly reloaded snapshot after saving, or
// validation issues when Core rejected one or more entries.
type FileTypeMappingsSaveResult struct {
	Snapshot FileTypeMappingsSnapshot
	Issues   []core.FileTypeMappingIssue
}

// FileTypeMappingsSource reads and writes global and project file type mappings off the UI thread.
type FileTypeMappingsSource interface {
	Load(ctx context.Context) (FileTypeMappingsSnapshot, error)
	Save(ctx context.Context, base, next FileTypeMappingsSnapshot) (FileTypeMappingsSaveResult, error)
}

func cloneFileTypeMappingsSnapshot(src FileTypeMappingsSnapshot) FileTypeMappingsSnapshot {
	out := src
	out.Global = append([]core.FileTypeMapping(nil), src.Global...)
	out.Project = append([]core.FileTypeMapping(nil), src.Project...)
	out.Builtins = append([]core.FileTypeMapping(nil), src.Builtins...)
	out.KnownLanguageIDs = append([]string(nil), src.KnownLanguageIDs...)
	return out
}
