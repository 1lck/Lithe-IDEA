package remoteconn

import (
	"context"
	"errors"

	"github.com/1lck/Lithe-IDEA/desktop/internal/configfile"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// Remote workspace trust lives in <preference root>/toolchains/remote-trust.json, the path and the
// size limit Core names (remote.workspaceTrust), next to the local trust catalog in the platform
// user preference directory. It is owned by this machine's user, created on the first decision
// and only ever replaced whole, atomically, against the bytes it was read from. It is never written
// to a host, a workspace, the app bundle or the installation directory, so it does not affect code
// signing or Sparkle delta updates, and it is not copied across worktrees. Decisions are keyed by
// Core on the connection's target and the workspace's real path on the host, and never apply to
// local workspaces.

// TrustKernel is the part of the Core client remote workspace trust uses.
type TrustKernel interface {
	RemoteWorkspaceTrust(ctx context.Context, document *string, sessionID, workspace string) (core.RemoteWorkspaceTrustState, error)
	EditRemoteWorkspaceTrust(ctx context.Context, document *string, decision core.RemoteWorkspaceTrustDecision) (core.RemoteWorkspaceTrustPublication, error)
}

// Trust is the remote trust document with the bytes it was read from, and the trust of the
// workspace it was read for.
type Trust struct {
	// State is Core's reading, with WorkspaceTrust set for the workspace ReadTrust named.
	State core.RemoteWorkspaceTrustState
	root  string
	file  configfile.Snapshot
}

// ReadTrust reads the remote trust document kept under root, the platform preference directory,
// and the trust of workspace opened over the session sessionID. Reading creates nothing. A
// document Core cannot decode fails with ErrDamaged joined to Core's error.
func ReadTrust(ctx context.Context, kernel TrustKernel, root, sessionID, workspace string) (Trust, error) {
	if root == "" {
		return Trust{}, ErrUnavailable
	}
	plan, err := kernel.RemoteWorkspaceTrust(ctx, nil, "", "")
	if err != nil {
		return Trust{}, err
	}
	file, err := configfile.Capture(ctx, root, plan.Storage.RelativePath, plan.Storage.MaximumBytes)
	if errors.Is(err, configfile.ErrTooLarge) || errors.Is(err, configfile.ErrEncoding) {
		return Trust{}, errors.Join(ErrDamaged, err)
	}
	if err != nil {
		return Trust{}, err
	}
	text, err := file.Text()
	if err != nil {
		return Trust{}, errors.Join(ErrDamaged, err)
	}
	state, err := kernel.RemoteWorkspaceTrust(ctx, text, sessionID, workspace)
	if err != nil {
		var coreErr *core.Error
		if errors.As(err, &coreErr) && coreErr.Code == core.CodeParseFailed {
			err = errors.Join(ErrDamaged, err)
		}
		return Trust{}, err
	}
	return Trust{State: state, root: root, file: file}, nil
}

// Decide records decision against the bytes t was read from and publishes the result. A file
// changed since t was read fails with ErrConflict and writes nothing; committed reports that the
// new document reached the disk even when a later step failed.
func (t Trust) Decide(ctx context.Context, kernel TrustKernel, decision core.RemoteWorkspaceTrustDecision) (committed bool, err error) {
	if t.root == "" {
		return false, ErrUnavailable
	}
	text, err := t.file.Text()
	if err != nil {
		return false, errors.Join(ErrDamaged, err)
	}
	publication, err := kernel.EditRemoteWorkspaceTrust(ctx, text, decision)
	if err != nil {
		var coreErr *core.Error
		if errors.As(err, &coreErr) && coreErr.Code == core.CodeParseFailed {
			err = errors.Join(ErrDamaged, err)
		}
		return false, err
	}
	if !publication.Changed {
		return false, nil
	}
	if publication.Document == nil {
		return false, errors.New("remoteconn: Core changed the trust decisions without a document")
	}
	committed, err = t.file.Replace(ctx, []byte(*publication.Document), func() error { return t.file.Verify(ctx) })
	if errors.Is(err, configfile.ErrConflict) {
		err = errors.Join(ErrConflict, err)
	}
	return committed, err
}
