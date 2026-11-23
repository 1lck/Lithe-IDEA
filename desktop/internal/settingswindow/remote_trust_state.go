package settingswindow

import (
	"context"
	"errors"
	"slices"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/remoteconn"
	"github.com/vivaui/viva/ui"
)

// RemoteTrustLoader reads the trust decisions this machine keeps on remote workspaces, per
// connection target, and removes them. Save removes each entry, in order, against the bytes the
// records were read from and re-reads them. All calls run off the window thread. Neither call
// needs an open connection.
type RemoteTrustLoader interface {
	LoadRemoteTrust(context.Context) (remoteconn.Trust, error)
	SaveRemoteTrust(context.Context, remoteconn.Trust, []core.RemoteWorkspaceTrustRevoke) (remoteconn.Trust, error)
}

// remoteTrustState is the Remote Workspaces card of the Trusted Locations page: the records Core
// read from the remote trust document (toolchains/remote-trust.json in the preference directory),
// the removals not applied yet and the requests that read and write them. Only the window thread
// touches the fields; each request is an Effect whose key changes when it is made, taken at the
// start of a paint.
//
// The document is its own file, written by project windows when a remote folder is trusted or
// kept in safe mode, so a write here is checked against the bytes it was read from and refused
// with remoteconn.ErrConflict when a project window wrote in between; the card reads the records
// again and keeps the removals that still name one.
type remoteTrustState struct {
	loader RemoteTrustLoader

	loadEffect *ui.EffectState[remoteconn.Trust, int]
	loadKey    int
	loading    bool
	loaded     bool
	// stale asks for a re-read before the card shows or writes again.
	stale      bool
	readFailed error
	source     remoteconn.Trust

	// revokes are the removals in the order the user made them.
	revokes []core.RemoteWorkspaceTrustRevoke

	saveEffect  *ui.EffectState[remoteconn.Trust, int]
	saveKey     int
	saveSource  remoteconn.Trust
	saveRevokes []core.RemoteWorkspaceTrustRevoke
	saving      bool
	// failed is the last write's error.
	failed error
}

// remoteTrustEntry is one record of a target: a folder in one of its three lists.
type remoteTrustEntry struct {
	list    string
	path    string
	revoked bool
}

// remoteTrustGroup is a connection target's records, in the order the card lists them.
type remoteTrustGroup struct {
	target  core.RemoteWorkspaceTrustTarget
	entries []remoteTrustEntry
}

func newRemoteTrustState(loader ToolchainLoader) *remoteTrustState {
	r := &remoteTrustState{}
	remote, ok := loader.(RemoteTrustLoader)
	if !ok {
		return r
	}
	r.loader = remote
	r.loadEffect = ui.NewEffect[remoteconn.Trust, int](func(ctx context.Context) (remoteconn.Trust, error) {
		return remote.LoadRemoteTrust(ctx)
	})
	r.saveEffect = ui.NewEffect[remoteconn.Trust, int](func(ctx context.Context) (remoteconn.Trust, error) {
		return remote.SaveRemoteTrust(ctx, r.saveSource, r.saveRevokes)
	})
	return r
}

func (r *remoteTrustState) available() bool { return r != nil && r.loader != nil }

func (r *remoteTrustState) busy() bool { return r.available() && (r.loading || r.saving) }

// ensureLoaded reads the records when the card shows and there are none, or they went stale.
func (r *remoteTrustState) ensureLoaded() {
	if !r.available() || r.busy() || r.readFailed != nil {
		return
	}
	if !r.loaded || r.stale {
		r.beginLoad()
	}
}

func (r *remoteTrustState) beginLoad() {
	r.loadKey++
	r.loading, r.readFailed = true, nil
}

// reload reads the records again; the removals that still name one stay.
func (r *remoteTrustState) reload() {
	if !r.available() || r.busy() {
		return
	}
	r.failed = nil
	r.beginLoad()
}

// toggle drafts removing the record, or drops the draft that already removes it.
func (r *remoteTrustState) toggle(target core.RemoteWorkspaceTrustTarget, list, path string) {
	if !r.available() || !r.loaded || r.busy() {
		return
	}
	r.failed = nil
	revoke := core.RemoteWorkspaceTrustRevoke{Target: target.Target, List: list, Path: path}
	if index := slices.IndexFunc(r.revokes, func(other core.RemoteWorkspaceTrustRevoke) bool { return sameRevoke(other, revoke) }); index >= 0 {
		r.revokes = slices.Delete(r.revokes, index, index+1)
		return
	}
	r.revokes = append(r.revokes, revoke)
}

// sameRevoke compares targets as Core wrote them; the card passes them back unchanged.
func sameRevoke(a, b core.RemoteWorkspaceTrustRevoke) bool {
	return a.List == b.List && a.Path == b.Path && string(a.Target) == string(b.Target)
}

// groups are the card's records: each target in Core's order, its trusted workspaces, then the
// ones kept in safe mode, then its trusted locations, each marked when a removal is drafted.
func (r *remoteTrustState) groups() []remoteTrustGroup {
	if !r.available() || !r.loaded {
		return nil
	}
	targets := r.source.State.Document.Targets
	groups := make([]remoteTrustGroup, 0, len(targets))
	for _, target := range targets {
		group := remoteTrustGroup{target: target}
		for _, list := range []struct {
			name  string
			paths []string
		}{
			{core.RemoteTrustTrustedWorkspaces, target.TrustedWorkspaces},
			{core.RemoteTrustDistrustedWorkspaces, target.DistrustedWorkspaces},
			{core.RemoteTrustTrustedLocations, target.TrustedLocations},
		} {
			for _, path := range list.paths {
				revoke := core.RemoteWorkspaceTrustRevoke{Target: target.Target, List: list.name, Path: path}
				revoked := slices.ContainsFunc(r.revokes, func(other core.RemoteWorkspaceTrustRevoke) bool { return sameRevoke(other, revoke) })
				group.entries = append(group.entries, remoteTrustEntry{list: list.name, path: path, revoked: revoked})
			}
		}
		groups = append(groups, group)
	}
	return groups
}

func (r *remoteTrustState) drafts() int {
	if !r.available() {
		return 0
	}
	return len(r.revokes)
}

// keepListed drops the removals whose record the records just read no longer hold.
func (r *remoteTrustState) keepListed() {
	r.revokes = slices.DeleteFunc(r.revokes, func(revoke core.RemoteWorkspaceTrustRevoke) bool {
		for _, group := range r.groups() {
			if string(group.target.Target) != string(revoke.Target) {
				continue
			}
			for _, entry := range group.entries {
				if entry.list == revoke.List && entry.path == revoke.Path {
					return false
				}
			}
		}
		return true
	})
}

// beginSave writes the removals against the records they were made on. Stale records are read
// again first; the caller tries again once that read is taken.
func (r *remoteTrustState) beginSave() bool {
	if !r.available() || !r.loaded || r.stale || r.busy() || r.drafts() == 0 {
		return false
	}
	r.saveSource, r.saveRevokes = r.source, slices.Clone(r.revokes)
	r.saveKey++
	r.saving, r.failed = true, nil
	return true
}

// take applies the card's finished requests and reports a write that failed, so the footer's
// apply stops.
func (r *remoteTrustState) take() (saveFailed error) {
	if !r.available() {
		return nil
	}
	if source, err, ok := r.loadEffect.Take(); ok {
		r.loading = false
		if err != nil {
			r.readFailed = err
		} else {
			r.source, r.loaded, r.stale = source, true, false
			r.keepListed()
		}
	}
	if source, err, ok := r.saveEffect.Take(); ok {
		r.saving = false
		switch {
		case err != nil:
			// A project window may have decided on a remote folder meanwhile
			// (remoteconn.ErrConflict), or the write reached the disk before a later step failed:
			// read the records again and keep the removals that still name one.
			r.failed, r.stale, saveFailed = err, true, err
		default:
			r.source, r.loaded, r.stale = source, true, false
			r.revokes = nil
		}
	}
	return saveFailed
}

// remoteTrustFailureMessage says why the records could not be read or written. Core's message
// may name host paths; it is shown, and the loader logs only its code.
func remoteTrustFailureMessage(language i18n.Language, err error) string {
	switch {
	case errors.Is(err, remoteconn.ErrConflict):
		return i18n.Shared(language, "desktop.trustedLocations.remoteConflict")
	case errors.Is(err, remoteconn.ErrDamaged):
		return i18n.Shared(language, "desktop.trustedLocations.remoteDamaged")
	}
	return i18n.SharedFormat(language, "desktop.trustedLocations.remoteFailed", map[string]string{"reason": err.Error()})
}

// declare keeps the requests that are out alive in every paint, so leaving the page does not
// cancel a write.
func (r *remoteTrustState) declare(c ui.C) {
	if !r.available() {
		return
	}
	if r.loadKey != 0 {
		ui.Effect(c, r.loadEffect, r.loadKey)
	}
	if r.saveKey != 0 {
		ui.Effect(c, r.saveEffect, r.saveKey)
	}
}
