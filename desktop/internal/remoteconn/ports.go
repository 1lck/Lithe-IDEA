package remoteconn

import (
	"context"
	"errors"

	"github.com/1lck/Lithe-IDEA/desktop/internal/configfile"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// What the Ports window of a remote workspace remembers (the ports the user added, their labels
// and local ports, the local forwards left running and the forwarding rules started on the host)
// lives in <preference root>/remote/ports.json, the path and the size limit Core names
// (remote.portRecords), next to the remote preferences in the platform user preference directory.
// It is machine-local and owned by this machine's user: created on the first change, and only ever
// replaced whole, atomically, against the bytes it was read from. Core keys every record by the
// connection's target and the workspace's real path on the host. The file is never written to a
// host, a workspace, the app bundle or the installation directory, so it does not affect code
// signing or Sparkle delta updates, and it is not copied across worktrees. It holds no secret:
// host addresses, port numbers, the user's labels and the addresses typed into the window.

// PortsKernel is the part of the Core client the port records use.
type PortsKernel interface {
	RemotePortRecords(ctx context.Context, document *string, sessionID, workspace string) (core.RemotePortRecordsState, error)
	EditRemotePortRecords(ctx context.Context, document *string, sessionID, workspace string, edit core.RemotePortRecordEdit) (changed bool, updated *string, records core.RemotePortRecords, err error)
	RestoreRemoteForwards(ctx context.Context, document *string, sessionID, workspace string) ([]core.RemoteRestoredForward, error)
}

// PortRecords is the port records document with the bytes it was read from, and the records of
// the workspace it was read for.
type PortRecords struct {
	// State is Core's reading for the workspace.
	State     core.RemotePortRecordsState
	root      string
	session   string
	workspace string
	file      configfile.Snapshot
}

// ReadPortRecords reads the port records kept under root, the platform preference directory, for
// workspace opened over the session sessionID. Reading creates nothing. A document Core cannot
// decode fails with ErrDamaged joined to Core's error; a closed session fails with Core's
// CodeConnectionClosed.
func ReadPortRecords(ctx context.Context, kernel PortsKernel, root, sessionID, workspace string) (PortRecords, error) {
	if root == "" {
		return PortRecords{}, ErrUnavailable
	}
	// Core names the storage only for an open workspace, so the first reading has no document.
	plan, err := kernel.RemotePortRecords(ctx, nil, sessionID, workspace)
	if err != nil {
		return PortRecords{}, err
	}
	file, err := configfile.Capture(ctx, root, plan.Storage.RelativePath, plan.Storage.MaximumBytes)
	if errors.Is(err, configfile.ErrTooLarge) || errors.Is(err, configfile.ErrEncoding) {
		return PortRecords{}, errors.Join(ErrDamaged, err)
	}
	if err != nil {
		return PortRecords{}, err
	}
	text, err := file.Text()
	if err != nil {
		return PortRecords{}, errors.Join(ErrDamaged, err)
	}
	state := plan
	if text != nil {
		if state, err = kernel.RemotePortRecords(ctx, text, sessionID, workspace); err != nil {
			return PortRecords{}, portRecordsError(err)
		}
	}
	return PortRecords{State: state, root: root, session: sessionID, workspace: workspace, file: file}, nil
}

// Edit applies edit to the bytes p was read from and publishes the result; after holds the
// workspace's records the edit leads to. An edit that changes nothing writes nothing. A refused
// value fails with Core's CodeInvalidRequest naming the field, and a file changed since p was read
// with ErrConflict, both without writing; committed reports that the new document reached the disk.
func (p PortRecords) Edit(ctx context.Context, kernel PortsKernel, edit core.RemotePortRecordEdit) (after core.RemotePortRecords, committed bool, err error) {
	if p.root == "" {
		return p.State.Records, false, ErrUnavailable
	}
	text, err := p.file.Text()
	if err != nil {
		return p.State.Records, false, errors.Join(ErrDamaged, err)
	}
	changed, document, after, err := kernel.EditRemotePortRecords(ctx, text, p.session, p.workspace, edit)
	if err != nil {
		return p.State.Records, false, portRecordsError(err)
	}
	if !changed {
		return after, false, nil
	}
	if document == nil {
		return p.State.Records, false, errors.New("remoteconn: Core changed the port records without a document")
	}
	committed, err = p.file.Replace(ctx, []byte(*document), func() error { return p.file.Verify(ctx) })
	if errors.Is(err, configfile.ErrConflict) {
		err = errors.Join(ErrConflict, err)
	}
	return after, committed, err
}

// Restore starts again the local forwards p records as left running, as
// core.Client.RestoreRemoteForwards does.
func (p PortRecords) Restore(ctx context.Context, kernel PortsKernel) ([]core.RemoteRestoredForward, error) {
	if p.root == "" {
		return nil, ErrUnavailable
	}
	text, err := p.file.Text()
	if err != nil {
		return nil, errors.Join(ErrDamaged, err)
	}
	restored, err := kernel.RestoreRemoteForwards(ctx, text, p.session, p.workspace)
	if err != nil {
		return nil, portRecordsError(err)
	}
	return restored, nil
}

// portRecordsError marks Core's refusal to decode the stored document as ErrDamaged.
func portRecordsError(err error) error {
	var coreErr *core.Error
	if errors.As(err, &coreErr) && coreErr.Code == core.CodeParseFailed {
		return errors.Join(ErrDamaged, err)
	}
	return err
}
