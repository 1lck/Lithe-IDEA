package toolchain

import (
	"context"

	"github.com/1lck/Lithe-IDEA/desktop/internal/configfile"
)

type sourceRevisionKernel interface {
	Kernel
	catalogReader
}

// SourceRevision identifies the saved input files of one workspace's toolchain
// resolver. It holds no configuration bytes, tool selections or discovery state.
type SourceRevision struct {
	project configfile.Revision
	global  configfile.Revision
}

func (r SourceRevision) Equal(other SourceRevision) bool {
	return r.project.Equal(other.project) && r.global.Equal(other.global)
}

// ReadSourceRevision reads the same bounded files as Resolve, without decoding
// their content or probing tools. Separate clients therefore agree on whether
// a provider predates a committed settings change.
func ReadSourceRevision(ctx context.Context, kernel sourceRevisionKernel, root, globalRoot, platform string) (SourceRevision, error) {
	project, _, err := capturePinFile(ctx, kernel, root)
	if err != nil {
		return SourceRevision{}, err
	}
	var global configfile.Snapshot
	if globalRoot != "" {
		global, err = captureCatalogFile(ctx, kernel, globalRoot, platform)
		if err != nil {
			return SourceRevision{}, err
		}
	}
	return SourceRevision{project: project.Revision(), global: global.Revision()}, nil
}
