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
	RevokeRemoteWorkspaceTrust(ctx context.Context, document *string, revoke core.RemoteWorkspaceTrustRevoke) (core.RemoteWorkspaceTrustPublication, error)
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
		return false, trustEditError(err)
	}
	if !publication.Changed {
		return false, nil
	}
	if publication.Document == nil {
		return false, errNoTrustDocument
	}
	return t.publish(ctx, *publication.Document)
}

// Revoke removes each entry of revokes, in order, from the bytes t was read from, and publishes
// the result once when any removal changed it; after is the document it leads to. Nothing is
// written when Core refuses a removal or when none changes anything. A file changed since t was
// read fails with ErrConflict and writes nothing; committed reports that the new document reached
// the disk even when a later step failed. Revoking needs no open connection.
func (t Trust) Revoke(ctx context.Context, kernel TrustKernel, revokes []core.RemoteWorkspaceTrustRevoke) (after core.RemoteWorkspaceTrustDocument, committed bool, err error) {
	if t.root == "" {
		return t.State.Document, false, ErrUnavailable
	}
	text, err := t.file.Text()
	if err != nil {
		return t.State.Document, false, errors.Join(ErrDamaged, err)
	}
	after, changed := t.State.Document, false
	for _, revoke := range revokes {
		publication, err := kernel.RevokeRemoteWorkspaceTrust(ctx, text, revoke)
		if err != nil {
			return t.State.Document, false, trustEditError(err)
		}
		after = publication.Decisions
		if publication.Changed {
			if publication.Document == nil {
				return t.State.Document, false, errNoTrustDocument
			}
			text, changed = publication.Document, true
		}
	}
	if !changed {
		return after, false, nil
	}
	committed, err = t.publish(ctx, *text)
	return after, committed, err
}

var errNoTrustDocument = errors.New("remoteconn: Core changed the trust decisions without a document")

// trustEditError marks Core's refusal to decode the stored document as ErrDamaged.
func trustEditError(err error) error {
	var coreErr *core.Error
	if errors.As(err, &coreErr) && coreErr.Code == core.CodeParseFailed {
		return errors.Join(ErrDamaged, err)
	}
	return err
}

// publish replaces the file with document, against the bytes t was read from.
func (t Trust) publish(ctx context.Context, document string) (committed bool, err error) {
	committed, err = t.file.Replace(ctx, []byte(document), func() error { return t.file.Verify(ctx) })
	if errors.Is(err, configfile.ErrConflict) {
		err = errors.Join(ErrConflict, err)
	}
	return committed, err
}
