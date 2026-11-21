package settingswindow

import (
	"context"
	"errors"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/toolchain"
)

// fakeLocationsLoader keeps a trusted folder list the way Core edits it: a change removes the
// folder, an add then appends it, and a filesystem root is refused. A write checks it is made
// on the list last read.
type fakeLocationsLoader struct {
	fakeToolchainLoader
	mu        sync.Mutex
	locations []string
	// commitErr is returned after a write lands, as when the read-back fails.
	commitErr error
	saved     chan []toolchain.LocationChange
	// locationLoads counts the reads; the window reads on an effect goroutine.
	locationLoads atomic.Int32
}

func (f *fakeLocationsLoader) LoadTrustedLocations(context.Context) (toolchain.TrustedLocations, error) {
	f.locationLoads.Add(1)
	f.mu.Lock()
	defer f.mu.Unlock()
	return toolchain.TrustedLocations{Locations: slices.Clone(f.locations)}, nil
}

func (f *fakeLocationsLoader) PreviewTrustedLocations(_ context.Context, source toolchain.TrustedLocations, changes []toolchain.LocationChange) ([]string, error) {
	return replayLocations(source.Locations, changes)
}

func (f *fakeLocationsLoader) SaveTrustedLocations(_ context.Context, source toolchain.TrustedLocations, changes []toolchain.LocationChange) (toolchain.TrustedLocations, error) {
	if f.saved != nil {
		select {
		case f.saved <- slices.Clone(changes):
		default:
		}
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if !slices.Equal(source.Locations, f.locations) {
		return source, toolchain.ErrPinConflict
	}
	locations, err := replayLocations(f.locations, changes)
	if err != nil {
		return source, err
	}
	f.locations = locations
	if f.commitErr != nil {
		return source, f.commitErr
	}
	return toolchain.TrustedLocations{Locations: slices.Clone(locations)}, nil
}

func (f *fakeLocationsLoader) set(locations ...string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.locations = locations
}

func (f *fakeLocationsLoader) list() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return slices.Clone(f.locations)
}

func replayLocations(list []string, changes []toolchain.LocationChange) ([]string, error) {
	out := slices.Clone(list)
	for index, change := range changes {
		if change.Folder == "/" {
			return nil, &toolchain.LocationChangeError{Index: index, Err: &core.MarketplaceRejection{Code: "plugin.toolchain.rootLocation", Message: "fixture root diagnostic"}}
		}
		out = slices.DeleteFunc(out, func(folder string) bool { return folder == change.Folder })
		if change.Add {
			out = append(out, change.Folder)
		}
	}
	return out, nil
}

const (
	savedFolder = "/fixture/saved"
	addedFolder = "/fixture/added"
	otherFolder = "/fixture/other"
)

// locationsWindow opens a settings window on page with loader and waits for the trusted
// folder list.
func locationsWindow(t *testing.T, loader *fakeLocationsLoader, page pageID) (*window, *windowDriver, *trustedLocationsState) {
	t.Helper()
	w := newWindow(NewController(Options{Toolchains: loader}), Values{})
	w.sess.page = page
	d := openWindow(t, w)
	l := w.toolchains.locations
	d.until("the trusted folders to load", func() bool { return l.loaded && !l.busy() })
	d.pump()
	return w, d, l
}

// changeLocation makes one change as the page's controls do and waits for Core's check.
func (d *windowDriver) changeLocation(l *trustedLocationsState, folder string, add bool) {
	d.t.Helper()
	l.change(folder, add)
	d.until("the change to be checked", func() bool { return !l.previewing })
	d.pump()
}

func locationMarks(l *trustedLocationsState) map[string]locationMark {
	marks := map[string]locationMark{}
	for _, row := range l.rows() {
		marks[row.folder] = row.mark
	}
	return marks
}

// Adding and removing folders are drafts marked in the list until Apply writes them; undoing a
// change takes its mark away, and opening the page writes nothing.
func TestTrustedLocationsDraftsAreMarkedUndoneAndApplied(t *testing.T) {
	loader := &fakeLocationsLoader{saved: make(chan []toolchain.LocationChange, 1)}
	loader.set(savedFolder)
	w, d, l := locationsWindow(t, loader, pageTrustedLocations)
	if !d.text(filepath.FromSlash(savedFolder)) {
		t.Fatal("the saved folder is not listed")
	}
	select {
	case changes := <-loader.saved:
		t.Fatalf("opening the page wrote %v", changes)
	default:
	}

	d.changeLocation(l, addedFolder, true)
	d.click(en("desktop.trustedLocations.remove"))
	d.until("the removal to be checked", func() bool { return !l.previewing })
	d.pump()
	if marks := locationMarks(l); marks[savedFolder] != locationRemoved || marks[addedFolder] != locationAdded || l.drafts() != 2 {
		t.Fatalf("marks = %v, drafts = %d", marks, l.drafts())
	}
	if !d.text(en("desktop.trustedLocations.pendingAdd")) || !d.text(en("desktop.trustedLocations.pendingRemove")) {
		t.Fatal("the drafts are not tagged")
	}

	// The saved folder's row is drawn first: undo its removal.
	d.clickHit(d.first(en("desktop.buildSettings.undoChange")))
	d.until("the undo to be checked", func() bool { return !l.previewing })
	d.pump()
	if marks := locationMarks(l); marks[savedFolder] != locationSaved || marks[addedFolder] != locationAdded || l.drafts() != 1 {
		t.Fatalf("after undo marks = %v, drafts = %d", marks, l.drafts())
	}

	d.applyBuild()
	if w.apply.failed != nil {
		t.Fatalf("apply failed: %v", w.apply.failed)
	}
	if got, want := loader.list(), []string{savedFolder, addedFolder}; !slices.Equal(got, want) {
		t.Fatalf("written list = %v, want %v", got, want)
	}
	if l.drafts() != 0 || !slices.Equal(l.source.Locations, []string{savedFolder, addedFolder}) {
		t.Fatalf("after apply the page shows %v with %d drafts", l.source.Locations, l.drafts())
	}
}

// Core's refusal of a folder shows under the list and drops only that change.
func TestTrustedLocationsRefusalKeepsTheOtherDrafts(t *testing.T) {
	loader := &fakeLocationsLoader{}
	loader.set(savedFolder)
	_, d, l := locationsWindow(t, loader, pageTrustedLocations)
	d.changeLocation(l, addedFolder, true)
	d.changeLocation(l, "/", true)
	if l.refused == nil || l.drafts() != 1 || locationMarks(l)[addedFolder] != locationAdded {
		t.Fatalf("refused = %v, drafts = %d", l.refused, l.drafts())
	}
	message := toolchainFailureMessage(i18n.English, l.refused)
	if message != en("desktop.trustedLocations.rootLocation") {
		t.Fatalf("refusal message = %q", message)
	}
	if !d.showsWrapped(message) {
		t.Fatal("the refusal is not on the page")
	}
	if strings.Contains(message, "fixture") {
		t.Fatalf("the refusal shows Core's diagnostic: %q", message)
	}
}

// A write elsewhere makes the list stale; Apply reads it again and writes the drafts on what it
// read, so it keeps the folder the other write added.
func TestTrustedLocationsApplyReadsAStaleListFirst(t *testing.T) {
	loader := &fakeLocationsLoader{saved: make(chan []toolchain.LocationChange, 1)}
	loader.set(savedFolder)
	w, d, l := locationsWindow(t, loader, pageTrustedLocations)
	d.changeLocation(l, addedFolder, true)
	// Leave for a page that does not read the list, so only the apply can.
	w.sess.page = pageConsole
	d.pump()
	loader.set(savedFolder, otherFolder)
	l.markStale()
	before := loader.locationLoads.Load()
	d.applyBuild()
	if w.apply.failed != nil {
		t.Fatalf("apply failed: %v", w.apply.failed)
	}
	if loader.locationLoads.Load() <= before {
		t.Fatal("the apply wrote without reading the stale list")
	}
	if got, want := loader.list(), []string{savedFolder, otherFolder, addedFolder}; !slices.Equal(got, want) {
		t.Fatalf("written list = %v, want %v", got, want)
	}
	if l.drafts() != 0 {
		t.Fatalf("drafts after apply = %d", l.drafts())
	}
}

// A write that landed but could not be read back leaves no list to show: the page reads it
// again, and the drafts, now on disk, are gone.
func TestTrustedLocationsCommittedApplyReadsTheListAgain(t *testing.T) {
	loader := &fakeLocationsLoader{commitErr: errors.Join(toolchain.ErrPinCommitted, errors.New("readback failed"))}
	loader.set(savedFolder)
	w, d, l := locationsWindow(t, loader, pageTrustedLocations)
	d.changeLocation(l, addedFolder, true)
	before := loader.locationLoads.Load()
	d.applyBuild()
	if !errors.Is(w.apply.failed, toolchain.ErrPinCommitted) {
		t.Fatalf("footer failure = %v", w.apply.failed)
	}
	d.until("the list to be read again", func() bool { return loader.locationLoads.Load() > before && l.loaded && !l.busy() })
	if l.drafts() != 0 || locationMarks(l)[addedFolder] != locationSaved {
		t.Fatalf("after the committed write marks = %v, drafts = %d", locationMarks(l), l.drafts())
	}
}
