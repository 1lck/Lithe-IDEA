package settingswindow

import (
	"context"
	"errors"
	"slices"

	"github.com/1lck/Lithe-IDEA/desktop/internal/toolchain"
	"github.com/vivaui/viva/ui"
)

// trustedLocationsState is the Trusted Locations page: the folders Core read from the machine
// catalog (toolchains/global.json in the preference directory), the user's changes that are
// not applied yet and the requests that read, check and write them. Only the window thread
// touches the fields; each request is an Effect whose key changes when it is made, taken at the
// start of a paint.
//
// It belongs to toolchainState because both write the same catalog file: owner.busy() covers
// every request of either, so a locations write never races a toolchain default or a trust
// decision, and each write marks what the other read as stale.
type trustedLocationsState struct {
	loader TrustedLocationsLoader
	owner  *toolchainState

	loadEffect *ui.EffectState[toolchain.TrustedLocations, int]
	loadKey    int
	loading    bool
	loaded     bool
	// stale asks for a re-read before the page shows or writes again, after another write
	// changed the catalog file.
	stale bool
	// readFailed is the last read's error; the page offers to read again.
	readFailed error
	source     toolchain.TrustedLocations

	// changes are the user's changes in the order made; shown is the list Core says they lead
	// to. Both are empty when nothing differs from source.
	changes []toolchain.LocationChange
	shown   []string

	previewEffect  *ui.EffectState[[]string, int]
	previewKey     int
	previewSource  toolchain.TrustedLocations
	previewChanges []toolchain.LocationChange
	// previewPick says the request checks a change the user just made, which Core's refusal
	// drops; otherwise it checks the kept changes again after a re-read.
	previewPick bool
	previewing  bool
	// refused is Core's refusal of the user's last change, shown under the list.
	refused error

	saveEffect  *ui.EffectState[toolchain.TrustedLocations, int]
	saveKey     int
	saveSource  toolchain.TrustedLocations
	saveChanges []toolchain.LocationChange
	saving      bool
	// failed is the last write's error, or the re-check's of kept changes.
	failed error
}

// locationMark is how a folder of the page's list differs from what is saved.
type locationMark int

const (
	locationSaved locationMark = iota
	locationAdded
	locationRemoved
)

type locationRow struct {
	folder string
	mark   locationMark
}

func newTrustedLocationsState(owner *toolchainState, loader ToolchainLoader) *trustedLocationsState {
	l := &trustedLocationsState{owner: owner}
	locations, ok := loader.(TrustedLocationsLoader)
	if !ok {
		return l
	}
	l.loader = locations
	l.loadEffect = ui.NewEffect[toolchain.TrustedLocations, int](func(ctx context.Context) (toolchain.TrustedLocations, error) {
		return locations.LoadTrustedLocations(ctx)
	})
	l.previewEffect = ui.NewEffect[[]string, int](func(ctx context.Context) ([]string, error) {
		return locations.PreviewTrustedLocations(ctx, l.previewSource, l.previewChanges)
	})
	l.saveEffect = ui.NewEffect[toolchain.TrustedLocations, int](func(ctx context.Context) (toolchain.TrustedLocations, error) {
		return locations.SaveTrustedLocations(ctx, l.saveSource, l.saveChanges)
	})
	return l
}

func (l *trustedLocationsState) available() bool { return l != nil && l.loader != nil }

// busy reports a request of the page that is out; owner.busy() includes it.
func (l *trustedLocationsState) busy() bool {
	return l.available() && (l.loading || l.previewing || l.saving)
}

// ensureLoaded reads the list when the page shows and there is none, or the one there is
// went stale. It waits for every request on the catalog that is out.
func (l *trustedLocationsState) ensureLoaded() {
	if !l.available() || l.owner.busy() || l.readFailed != nil {
		return
	}
	if !l.loaded || l.stale {
		l.beginLoad()
	}
}

func (l *trustedLocationsState) beginLoad() {
	l.loadKey++
	l.loading, l.readFailed = true, nil
}

// reload reads the list again; the changes stay and are checked against what it reads.
func (l *trustedLocationsState) reload() {
	if !l.available() || l.owner.busy() {
		return
	}
	l.failed, l.refused = nil, nil
	l.beginLoad()
}

// markStale asks for a re-read after another write changed the catalog file.
func (l *trustedLocationsState) markStale() {
	if l.available() && l.loaded {
		l.stale = true
	}
}

// change records one change once Core accepted it: the list shows what all changes lead to.
func (l *trustedLocationsState) change(folder string, add bool) {
	if !l.available() || !l.loaded || folder == "" || l.owner.busy() {
		return
	}
	l.refused, l.failed = nil, nil
	l.beginPreview(append(slices.Clone(l.changes), toolchain.LocationChange{Folder: folder, Add: add}), true)
}

// undo drops every change of folder, so the folder is back where the saved list has it; adding
// the opposite change instead would move a restored folder to the end.
func (l *trustedLocationsState) undo(folder string) {
	if !l.available() || !l.loaded || l.owner.busy() {
		return
	}
	l.refused, l.failed = nil, nil
	kept := slices.DeleteFunc(slices.Clone(l.changes), func(change toolchain.LocationChange) bool { return change.Folder == folder })
	l.beginPreview(kept, true)
}

func (l *trustedLocationsState) beginPreview(changes []toolchain.LocationChange, pick bool) {
	l.previewSource, l.previewChanges, l.previewPick = l.source, changes, pick
	l.previewKey++
	l.previewing = true
}

// rows are the page's list: the saved folders in their order, each marked when the changes
// remove it, then the folders the changes add.
func (l *trustedLocationsState) rows() []locationRow {
	if !l.available() || !l.loaded {
		return nil
	}
	rows := make([]locationRow, 0, len(l.source.Locations)+len(l.shown))
	for _, folder := range l.source.Locations {
		mark := locationSaved
		if len(l.changes) > 0 && !slices.Contains(l.shown, folder) {
			mark = locationRemoved
		}
		rows = append(rows, locationRow{folder: folder, mark: mark})
	}
	for _, folder := range l.shown {
		if !slices.Contains(l.source.Locations, folder) {
			rows = append(rows, locationRow{folder: folder, mark: locationAdded})
		}
	}
	return rows
}

// drafts counts the folders the changes add or remove.
func (l *trustedLocationsState) drafts() int {
	count := 0
	for _, row := range l.rows() {
		if row.mark != locationSaved {
			count++
		}
	}
	return count
}

// beginSave writes the changes against the list they were made on. A stale list is read
// again first; the caller tries again once that read is taken.
func (l *trustedLocationsState) beginSave() bool {
	if !l.available() || !l.loaded || l.stale || l.owner.busy() || l.drafts() == 0 {
		return false
	}
	l.saveSource, l.saveChanges = l.source, slices.Clone(l.changes)
	l.saveKey++
	l.saving, l.failed = true, nil
	return true
}

// take applies the page's finished requests and reports a write that failed, so the footer's
// apply stops.
func (l *trustedLocationsState) take() (saveFailed error) {
	if !l.available() {
		return nil
	}
	if source, err, ok := l.loadEffect.Take(); ok {
		l.loading = false
		if err != nil {
			l.readFailed = err
		} else {
			l.source, l.loaded, l.stale = source, true, false
			if len(l.changes) > 0 {
				// Core checks the kept changes on what was read; the list shows the result.
				l.beginPreview(l.changes, false)
			}
		}
	}
	if shown, err, ok := l.previewEffect.Take(); ok {
		l.previewing = false
		switch {
		case err != nil && l.previewPick:
			l.refused = err
		case err != nil:
			l.failed = err
		default:
			l.changes, l.shown = l.previewChanges, shown
			if l.drafts() == 0 {
				l.changes, l.shown = nil, nil
			}
		}
	}
	if source, err, ok := l.saveEffect.Take(); ok {
		l.saving = false
		switch {
		case err != nil && errors.Is(err, toolchain.ErrPinCommitted):
			// The list was written but not read back: the changes are on disk, and the page
			// reads them before it shows the list again.
			l.failed, l.loaded, l.stale = err, false, true
			l.changes, l.shown = nil, nil
			l.owner.catalogWritten()
			saveFailed = err
		case err != nil:
			l.failed, saveFailed = err, err
		default:
			l.source, l.loaded, l.stale = source, true, false
			l.changes, l.shown, l.refused = nil, nil, nil
			l.owner.catalogWritten()
		}
	}
	return saveFailed
}

// declare keeps the requests that are out alive in every paint, so leaving the page does not
// cancel a write.
func (l *trustedLocationsState) declare(c ui.C) {
	if !l.available() {
		return
	}
	if l.loadKey != 0 {
		ui.Effect(c, l.loadEffect, l.loadKey)
	}
	if l.previewKey != 0 {
		ui.Effect(c, l.previewEffect, l.previewKey)
	}
	if l.saveKey != 0 {
		ui.Effect(c, l.saveEffect, l.saveKey)
	}
}
