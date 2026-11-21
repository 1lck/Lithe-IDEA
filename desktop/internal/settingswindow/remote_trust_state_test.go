package settingswindow

import (
	"context"
	"encoding/json"
	"errors"
	"slices"
	"sync"
	"sync/atomic"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/remoteconn"
	"github.com/vivaui/viva/gfx"
)

// fakeRemoteTrustLoader keeps remote trust records the way Core edits them: a removal takes the
// path out of the target's list and drops a target left empty, and a removal naming nothing
// changes nothing. A write made on records other than the ones it holds is refused with
// remoteconn.ErrConflict, as a file changed since it was read is.
type fakeRemoteTrustLoader struct {
	fakeLocationsLoader
	trustMu  sync.Mutex
	document core.RemoteWorkspaceTrustDocument
	// trustLoads and trustSaves count the requests; the window makes them on effect goroutines.
	trustLoads atomic.Int32
	trustSaves atomic.Int32
}

func (f *fakeRemoteTrustLoader) LoadRemoteTrust(context.Context) (remoteconn.Trust, error) {
	f.trustLoads.Add(1)
	f.trustMu.Lock()
	defer f.trustMu.Unlock()
	return remoteconn.Trust{State: core.RemoteWorkspaceTrustState{Document: cloneTrustDocument(f.document)}}, nil
}

func (f *fakeRemoteTrustLoader) SaveRemoteTrust(_ context.Context, source remoteconn.Trust, revokes []core.RemoteWorkspaceTrustRevoke) (remoteconn.Trust, error) {
	f.trustSaves.Add(1)
	f.trustMu.Lock()
	defer f.trustMu.Unlock()
	if trustText(source.State.Document) != trustText(f.document) {
		return source, remoteconn.ErrConflict
	}
	for _, revoke := range revokes {
		f.document = revokeTrust(f.document, revoke)
	}
	return remoteconn.Trust{State: core.RemoteWorkspaceTrustState{Document: cloneTrustDocument(f.document)}}, nil
}

func (f *fakeRemoteTrustLoader) set(targets ...core.RemoteWorkspaceTrustTarget) {
	f.trustMu.Lock()
	defer f.trustMu.Unlock()
	f.document = core.RemoteWorkspaceTrustDocument{Version: 1, Targets: targets}
}

func (f *fakeRemoteTrustLoader) stored() core.RemoteWorkspaceTrustDocument {
	f.trustMu.Lock()
	defer f.trustMu.Unlock()
	return cloneTrustDocument(f.document)
}

func trustText(document core.RemoteWorkspaceTrustDocument) string {
	text, err := json.Marshal(document)
	if err != nil {
		panic(err)
	}
	return string(text)
}

func cloneTrustDocument(document core.RemoteWorkspaceTrustDocument) core.RemoteWorkspaceTrustDocument {
	var clone core.RemoteWorkspaceTrustDocument
	if err := json.Unmarshal([]byte(trustText(document)), &clone); err != nil {
		panic(err)
	}
	return clone
}

func revokeTrust(document core.RemoteWorkspaceTrustDocument, revoke core.RemoteWorkspaceTrustRevoke) core.RemoteWorkspaceTrustDocument {
	targets := document.Targets[:0:0]
	for _, target := range document.Targets {
		if string(target.Target) == string(revoke.Target) {
			drop := func(paths []string) []string {
				return slices.DeleteFunc(slices.Clone(paths), func(path string) bool { return path == revoke.Path })
			}
			switch revoke.List {
			case core.RemoteTrustTrustedWorkspaces:
				target.TrustedWorkspaces = drop(target.TrustedWorkspaces)
			case core.RemoteTrustDistrustedWorkspaces:
				target.DistrustedWorkspaces = drop(target.DistrustedWorkspaces)
			case core.RemoteTrustTrustedLocations:
				target.TrustedLocations = drop(target.TrustedLocations)
			}
			if len(target.TrustedWorkspaces)+len(target.DistrustedWorkspaces)+len(target.TrustedLocations) == 0 {
				continue
			}
		}
		targets = append(targets, target)
	}
	document.Targets = targets
	return document
}

const (
	devboxTarget = `{"hops":[{"ssh":{"destination":"devbox","port":2222,"user":"dev"}}]}`
	labTarget    = `{"hops":[{"ssh":{"destination":"lab"}},{"container":{"engine":"docker","program":"docker","container":"web"}}]}`
)

func devboxRecords() core.RemoteWorkspaceTrustTarget {
	return core.RemoteWorkspaceTrustTarget{
		Target:               json.RawMessage(devboxTarget),
		Label:                "Dev box",
		TrustedWorkspaces:    []string{"/srv/app"},
		DistrustedWorkspaces: []string{"/srv/tmp"},
	}
}

func labRecords() core.RemoteWorkspaceTrustTarget {
	return core.RemoteWorkspaceTrustTarget{Target: json.RawMessage(labTarget), TrustedLocations: []string{"/work"}}
}

// remoteTrustWindow opens a settings window on the Trusted Locations page with loader and waits
// for both cards.
func remoteTrustWindow(t *testing.T, loader *fakeRemoteTrustLoader) (*window, *windowDriver, *remoteTrustState) {
	t.Helper()
	w := newWindow(NewController(Options{Toolchains: loader}), Values{})
	w.sess.page = pageTrustedLocations
	d := openWindow(t, w)
	r := w.toolchains.remote
	d.until("the remote trust records to load", func() bool {
		return r.loaded && !r.busy() && w.toolchains.locations.loaded && !w.toolchains.locations.busy()
	})
	d.pump()
	return w, d, r
}

// removeRemoteRecords clicks the remove buttons of the listed rows, counted from 0 in the order
// the card draws them. A removed row keeps its height, so the other buttons stay where they were.
func (d *windowDriver) removeRemoteRecords(rows ...int) {
	d.t.Helper()
	label := i18n.Shared(d.w.marketLanguage(), "desktop.trustedLocations.remoteRemove")
	var buttons []gfx.Hit
	for _, hit := range d.driver.Snapshot().Hits {
		if hit.Label == label && !hit.IsLabel && !hit.Backdrop && !hit.ID.IsZero() {
			buttons = append(buttons, hit)
		}
	}
	for _, row := range rows {
		if row >= len(buttons) {
			d.t.Fatalf("row %d has no remove button (%d buttons)", row, len(buttons))
		}
		d.clickHit(buttons[row])
	}
	d.pump()
}

func revokedEntries(r *remoteTrustState) (revoked []string) {
	for _, group := range r.groups() {
		for _, entry := range group.entries {
			if entry.revoked {
				revoked = append(revoked, entry.list+" "+entry.path)
			}
		}
	}
	return revoked
}

// The card names each connection by its label, or by its host when it has none, and lists its
// records under it. Opening the page writes nothing; a removal is a draft marked in the list that
// can be undone, and Apply writes it.
func TestRemoteTrustRecordsAreListedDraftedAndApplied(t *testing.T) {
	loader := &fakeRemoteTrustLoader{}
	loader.set(devboxRecords(), labRecords())
	w, d, r := remoteTrustWindow(t, loader)
	for _, shown := range []string{"Dev box", "dev@devbox:2222", "lab → docker:web", "/srv/app", "/srv/tmp", "/work",
		en("desktop.trustedLocations.remoteTrusted"), en("desktop.trustedLocations.remoteDistrusted"), en("desktop.trustedLocations.remoteLocation")} {
		if !d.text(shown) {
			t.Fatalf("the card does not show an expected text (%d chars)", len(shown))
		}
	}
	if loader.trustSaves.Load() != 0 {
		t.Fatal("opening the page wrote the remote trust records")
	}

	// The rows are drawn in order: the first button removes /srv/app, the second /srv/tmp.
	d.clickHit(d.first(en("desktop.trustedLocations.remoteRemove")))
	d.pump()
	if got := revokedEntries(r); !slices.Equal(got, []string{core.RemoteTrustTrustedWorkspaces + " /srv/app"}) || r.drafts() != 1 {
		t.Fatalf("revoked = %d entries, drafts = %d", len(got), r.drafts())
	}
	if !d.text(en("desktop.trustedLocations.pendingRemove")) {
		t.Fatal("the removal is not tagged")
	}
	d.click(en("desktop.buildSettings.undoChange"))
	d.pump()
	if r.drafts() != 0 {
		t.Fatalf("drafts after undo = %d", r.drafts())
	}

	d.removeRemoteRecords(1, 2)
	d.applyBuild()
	if w.apply.failed != nil {
		t.Fatalf("apply failed: %v", w.apply.failed)
	}
	stored := loader.stored()
	if len(stored.Targets) != 1 || !slices.Equal(stored.Targets[0].TrustedWorkspaces, []string{"/srv/app"}) || len(stored.Targets[0].DistrustedWorkspaces) != 0 {
		t.Fatalf("stored targets = %d", len(stored.Targets))
	}
	if r.drafts() != 0 || len(r.groups()) != 1 {
		t.Fatalf("after apply: drafts = %d, groups = %d", r.drafts(), len(r.groups()))
	}
	if d.text("lab → docker:web") {
		t.Fatal("the emptied connection is still listed")
	}
}

// A project window that changes the records while removals are drafted makes Apply fail with a
// conflict: the card reads the records again, keeps the removals that still name one and drops
// the rest, and the next Apply writes them.
func TestRemoteTrustConflictReadsAgainAndKeepsTheListedRemovals(t *testing.T) {
	loader := &fakeRemoteTrustLoader{}
	loader.set(devboxRecords(), labRecords())
	w, d, r := remoteTrustWindow(t, loader)
	d.removeRemoteRecords(1, 2)

	// Elsewhere: /work is no longer trusted and another folder is.
	changed := labRecords()
	changed.TrustedLocations = nil
	changed.TrustedWorkspaces = []string{"/work/api"}
	loader.set(devboxRecords(), changed)
	before := loader.trustLoads.Load()
	d.applyBuild()
	if !errors.Is(w.apply.failed, remoteconn.ErrConflict) {
		t.Fatalf("footer failure is a conflict = %v", errors.Is(w.apply.failed, remoteconn.ErrConflict))
	}
	d.until("the records to be read again", func() bool { return loader.trustLoads.Load() > before && r.loaded && !r.busy() && !r.stale })
	d.pump()
	if got := revokedEntries(r); !slices.Equal(got, []string{core.RemoteTrustDistrustedWorkspaces + " /srv/tmp"}) || r.drafts() != 1 {
		t.Fatalf("after the re-read: revoked = %d entries, drafts = %d", len(got), r.drafts())
	}
	if !d.showsWrapped(en("desktop.trustedLocations.remoteConflict")) {
		t.Fatal("the conflict is not on the page")
	}

	d.applyBuild()
	if w.apply.failed != nil {
		t.Fatalf("second apply failed: %v", w.apply.failed)
	}
	stored := loader.stored()
	if len(stored.Targets) != 2 || len(stored.Targets[0].DistrustedWorkspaces) != 0 || !slices.Equal(stored.Targets[1].TrustedWorkspaces, []string{"/work/api"}) {
		t.Fatalf("stored targets = %d", len(stored.Targets))
	}
	if r.failed != nil || r.drafts() != 0 {
		t.Fatalf("after the second apply: failed = %v, drafts = %d", r.failed != nil, r.drafts())
	}
}

// Without records the card says so; a loader that keeps no remote records shows no card.
func TestRemoteTrustCardShowsOnlyWithALoader(t *testing.T) {
	loader := &fakeRemoteTrustLoader{}
	loader.set()
	_, d, _ := remoteTrustWindow(t, loader)
	if !d.showsWrapped(en("desktop.trustedLocations.remoteEmpty")) || !d.text(en("desktop.trustedLocations.remote")) {
		t.Fatal("the empty remote card is not shown")
	}

	local := &fakeLocationsLoader{}
	_, d, _ = locationsWindow(t, local, pageTrustedLocations)
	if d.text(en("desktop.trustedLocations.remote")) {
		t.Fatal("a loader without remote records shows the remote card")
	}
}
