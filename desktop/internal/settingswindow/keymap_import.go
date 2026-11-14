package settingswindow

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"reflect"
	"slices"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/keymapimport"
	"github.com/1lck/Lithe-IDEA/desktop/internal/shortcuts"
	"github.com/vivaui/viva/ui"
)

var errKeymapImportConflict = errors.New("shortcut import has conflicts")
var errKeymapImportSkipped = errors.New("shortcut import contains rules that cannot be imported")
var errKeymapImportStale = errors.New("shortcut settings changed after preview")

type keymapImportWork struct {
	Path, Format, Name string
	Snapshot           keymapimport.Snapshot
	State              core.KeymapSchemes
	Current            shortcuts.Overrides
	Apply              bool
}
type keymapImportResult struct {
	Snapshot keymapimport.Snapshot
	Preview  keymapimport.Preview
	Scheme   core.KeymapSchemeResult
}

// The effect key owns all request inputs; cancellation or a new request cannot
// race with mutable window fields. Results are published only on the window thread.
type keymapImportState struct {
	open, busy, ready bool
	format            string
	name              ui.Field
	request           *keymapImportWork
	effect            *ui.EffectState[keymapImportResult, *keymapImportWork]
	result            keymapImportResult
	failure           error
	rows              ui.ListState
}

func keymapCatalog(current shortcuts.Overrides) []keymapimport.Action {
	actions := shortcuts.All()
	result := make([]keymapimport.Action, 0, len(actions))
	for _, action := range actions {
		keys := make([]string, 0)
		for _, key := range current.Effective(action) {
			keys = append(keys, shortcuts.Encode(key))
		}
		result = append(result, keymapimport.Action{ID: action.ID, Customized: current.Changed(action.ID), Keys: keys})
	}
	return result
}

func runKeymapImport(ctx context.Context, work *keymapImportWork) (keymapImportResult, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	var result keymapImportResult
	var err error
	if work.Apply {
		result.Snapshot = work.Snapshot
		if err = result.Snapshot.Revalidate(ctx); err != nil {
			return result, err
		}
	} else {
		result.Snapshot, err = keymapimport.Read(ctx, work.Path)
		if err != nil {
			return result, err
		}
	}
	result.Preview, err = keymapimport.Parse(work.Format, result.Snapshot.Content(), keymapCatalog(work.Current))
	if err != nil || !work.Apply {
		return result, err
	}
	if len(result.Preview.Conflicts) != 0 {
		return result, errKeymapImportConflict
	}
	if len(result.Preview.Imported) == 0 {
		return result, keymapimport.ErrSource
	}
	var id [16]byte
	if _, err = rand.Read(id[:]); err != nil {
		return result, err
	}
	// Both reducer steps are local values. Publish only the completed result, so a
	// failed name validation/update cannot create a partial scheme in user settings.
	copied, err := core.NewClient().ReduceKeymapSchemes(ctx, core.KeymapSchemeRequest{State: work.State, Current: work.Current, Operation: "saveAs", ID: hex.EncodeToString(id[:]), Name: work.Name})
	if err != nil {
		return result, err
	}
	bindings := result.Preview.Proposal
	if bindings == nil {
		bindings = shortcuts.Overrides{}
	}
	result.Scheme, err = core.NewClient().ReduceKeymapSchemes(ctx, core.KeymapSchemeRequest{State: copied.State, Operation: "update", Bindings: bindings})
	return result, err
}

func (w *window) startKeymapImport(work *keymapImportWork) {
	s := &w.keyImport
	if s.effect == nil {
		s.effect = ui.NewEffectKeyed[keymapImportResult, *keymapImportWork](runKeymapImport)
	}
	s.request, s.busy, s.failure, s.ready = work, true, nil, false
	// File selection completes after declaration; wake the idle page so it can
	// declare and start this request instead of waiting for another user event.
	w.inv.Invalidate()
}

func (w *window) takeKeymapImport() {
	s := &w.keyImport
	if s.effect == nil {
		return
	}
	result, err, ok := s.effect.Take()
	if !ok || !s.open || s.request == nil {
		return
	}
	w.finishKeymapImport(result, err)
}

func (w *window) finishKeymapImport(result keymapImportResult, err error) {
	s := &w.keyImport
	if !s.open || s.request == nil || w.sess.finished.Load() {
		return
	}
	s.busy = false
	if err == nil && (!reflect.DeepEqual(w.sess.values.Keymap, s.request.Current) || !reflect.DeepEqual(w.sess.values.KeymapSchemes, s.request.State)) {
		err = errKeymapImportStale
	}
	if err != nil {
		s.failure, s.ready = err, false
		w.reportEssentialsFailure("keymap_import", err)
		return
	}
	s.result, s.ready = result, true
	if s.request.Apply {
		w.sess.values.KeymapSchemes = result.Scheme.State
		w.sess.values.Keymap = shortcuts.Overrides(result.Scheme.Bindings)
		if set := w.ctrl.opts.SetKeymapSchemes; set != nil {
			set(result.Scheme)
		}
		w.closeKeymapImport()
	} else if len(result.Preview.Conflicts) > 0 {
		w.reportEssentialsFailure("keymap_import", errKeymapImportConflict)
	} else if len(result.Preview.Skipped) > 0 || result.Preview.Inherited {
		w.reportEssentialsFailure("keymap_import", errKeymapImportSkipped)
	}
}

// cloneImportInputs makes a stable background snapshot, including empty vs nil maps.
func (w *window) keymapImportInputs() (core.KeymapSchemes, shortcuts.Overrides) {
	state := w.sess.values.KeymapSchemes
	state.Schemes = append([]core.KeymapScheme(nil), state.Schemes...)
	clone := func(source map[string][]string) map[string][]string {
		if source == nil {
			return nil
		}
		result := make(map[string][]string, len(source))
		for key, value := range source {
			result[key] = slices.Clone(value)
		}
		return result
	}
	for i := range state.Schemes {
		state.Schemes[i].Bindings = clone(state.Schemes[i].Bindings)
	}
	return state, shortcuts.Overrides(clone(w.sess.values.Keymap))
}

func (w *window) closeKeymapImport() {
	s := &w.keyImport
	s.open, s.ready, s.busy = false, false, false
	s.request = nil
	s.result = keymapImportResult{}
	// Disappearing from declareWork cancels the page-owned effect. Drop our
	// reference too, so its captured source bytes are released after it stops.
	s.effect = nil
}
