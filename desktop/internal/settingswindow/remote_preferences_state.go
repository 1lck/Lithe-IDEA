package settingswindow

import (
	"context"
	"errors"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/remoteconn"
	"github.com/vivaui/viva/ui"
)

// RemotePreferences is what the Remote Workspace page shows: the preference document as Core read
// it, and what every value resolves to when it is automatic, so a choice of Automatic can name the
// program and the time it stands for even while a saved value overrides it.
type RemotePreferences struct {
	Saved     remoteconn.Preferences
	Automatic core.RemotePreferences
}

// RemotePreferencesLoader reads the remote workspace preferences of this machine and applies the
// page's edits. Save applies each edit, in order, against the bytes the preferences were read from
// and reads them again. All calls run off the window thread, and neither needs a connection.
type RemotePreferencesLoader interface {
	LoadRemotePreferences(context.Context) (RemotePreferences, error)
	SaveRemotePreferences(context.Context, RemotePreferences, []core.RemotePreferenceEdit) (RemotePreferences, error)
}

// remotePreferencesState is the Remote Workspace page: the preferences Core read from
// remote/preferences.json in the preference directory, the changes not applied yet and the
// requests that read and write them. Only the window thread touches the fields; each request is
// an Effect whose key changes when it is made, taken at the start of a paint.
//
// The file is its own, so a write is checked against the bytes it was read from and refused with
// remoteconn.ErrConflict when another window wrote in between; the page reads it again and keeps
// the drafts.
type remotePreferencesState struct {
	loader RemotePreferencesLoader

	loadEffect *ui.EffectState[RemotePreferences, int]
	loadKey    int
	loading    bool
	loaded     bool
	stale      bool
	readFailed error
	// damagedPath is the file a failed read could not decode, shown with the failure.
	damagedPath string
	source      RemotePreferences

	// program, limit, reverse and closing are the drafts; set says the user changed the value,
	// and a nil value drafts Automatic.
	program    *string
	programSet bool
	limit      *uint32
	limitSet   bool
	reverse    *bool
	reverseSet bool
	closing    *core.RemoteClosePrograms
	closingSet bool

	saveEffect *ui.EffectState[RemotePreferences, int]
	saveKey    int
	saveSource RemotePreferences
	saveEdits  []core.RemotePreferenceEdit
	saving     bool
	failed     error
}

func newRemotePreferencesState(loader ToolchainLoader) *remotePreferencesState {
	r := &remotePreferencesState{}
	prefs, ok := loader.(RemotePreferencesLoader)
	if !ok {
		return r
	}
	r.loader = prefs
	r.loadEffect = ui.NewEffect[RemotePreferences, int](func(ctx context.Context) (RemotePreferences, error) {
		return prefs.LoadRemotePreferences(ctx)
	})
	r.saveEffect = ui.NewEffect[RemotePreferences, int](func(ctx context.Context) (RemotePreferences, error) {
		return prefs.SaveRemotePreferences(ctx, r.saveSource, r.saveEdits)
	})
	return r
}

func (r *remotePreferencesState) available() bool { return r != nil && r.loader != nil }

func (r *remotePreferencesState) busy() bool { return r.available() && (r.loading || r.saving) }

// ensureLoaded reads the preferences when the page shows and there are none, or they went stale.
func (r *remotePreferencesState) ensureLoaded() {
	if !r.available() || r.busy() || r.readFailed != nil {
		return
	}
	if !r.loaded || r.stale {
		r.beginLoad()
	}
}

func (r *remotePreferencesState) beginLoad() {
	r.loadKey++
	r.loading, r.readFailed = true, nil
}

// reload reads the preferences again; the drafts stay.
func (r *remotePreferencesState) reload() {
	if !r.available() || r.busy() {
		return
	}
	r.failed = nil
	r.beginLoad()
}

// shownProgram is the SSH program the page shows: the draft, or the saved one; nil is Automatic.
func (r *remotePreferencesState) shownProgram() *string {
	if r.programSet {
		return r.program
	}
	return r.source.Saved.State.Preferences.SSHProgram
}

// shownLimit is the reconnect limit the page shows; nil is Automatic.
func (r *remotePreferencesState) shownLimit() *uint32 {
	if r.limitSet {
		return r.limit
	}
	return r.source.Saved.State.Preferences.ReconnectLimitSeconds
}

// shownReverse is whether the page shows reverse forwards allowed; nil is Automatic.
func (r *remotePreferencesState) shownReverse() *bool {
	if r.reverseSet {
		return r.reverse
	}
	return r.source.Saved.State.Preferences.AllowReverseForwarding
}

// setReverse drafts whether reverse forwards are allowed, nil for Automatic; choosing the saved
// value drops the draft.
func (r *remotePreferencesState) setReverse(allowed *bool) {
	if !r.available() || !r.loaded || r.busy() {
		return
	}
	r.failed = nil
	r.reverse, r.reverseSet = allowed, !sameBool(allowed, r.source.Saved.State.Preferences.AllowReverseForwarding)
}

// setProgram drafts the SSH program, nil for Automatic; choosing the saved value drops the draft.
func (r *remotePreferencesState) setProgram(path *string) {
	if !r.available() || !r.loaded || r.busy() {
		return
	}
	r.failed = nil
	r.program, r.programSet = path, !sameString(path, r.source.Saved.State.Preferences.SSHProgram)
}

// setLimit drafts the reconnect limit, nil for Automatic; choosing the saved value drops the draft.
func (r *remotePreferencesState) setLimit(seconds *uint32) {
	if !r.available() || !r.loaded || r.busy() {
		return
	}
	r.failed = nil
	r.limit, r.limitSet = seconds, !sameUint32(seconds, r.source.Saved.State.Preferences.ReconnectLimitSeconds)
}

// shownClosing is what closing a workspace does to the host's programs as the page shows it: the
// draft, or the saved choice; nil is Automatic, which asks every time.
func (r *remotePreferencesState) shownClosing() *core.RemoteClosePrograms {
	if r.closingSet {
		return r.closing
	}
	return r.source.Saved.State.Preferences.ClosePrograms
}

// setClosing drafts the closing choice, nil for Automatic; choosing the saved value drops the
// draft.
func (r *remotePreferencesState) setClosing(programs *core.RemoteClosePrograms) {
	if !r.available() || !r.loaded || r.busy() {
		return
	}
	r.failed = nil
	r.closing, r.closingSet = programs, !samePointer(programs, r.source.Saved.State.Preferences.ClosePrograms)
}

func sameString(a, b *string) bool { return samePointer(a, b) }

func sameUint32(a, b *uint32) bool { return samePointer(a, b) }

// samePointer says a and b are both nil or point to equal values.
func samePointer[T comparable](a, b *T) bool {
	return (a == nil) == (b == nil) && (a == nil || *a == *b)
}

func sameBool(a, b *bool) bool { return samePointer(a, b) }

func (r *remotePreferencesState) drafts() int {
	if !r.available() {
		return 0
	}
	n := 0
	if r.programSet {
		n++
	}
	if r.limitSet {
		n++
	}
	if r.reverseSet {
		n++
	}
	if r.closingSet {
		n++
	}
	return n
}

// edits are the drafts as Core edits, in the page's order.
func (r *remotePreferencesState) edits() []core.RemotePreferenceEdit {
	var edits []core.RemotePreferenceEdit
	if r.programSet {
		edits = append(edits, core.RemotePreferenceEdit{SSHProgram: &core.RemoteSSHProgramEdit{Path: r.program}})
	}
	if r.limitSet {
		edits = append(edits, core.RemotePreferenceEdit{ReconnectLimit: &core.RemoteReconnectLimitEdit{Seconds: r.limit}})
	}
	if r.reverseSet {
		edits = append(edits, core.RemotePreferenceEdit{Reverse: &core.RemoteReverseForwardingEdit{Allowed: r.reverse}})
	}
	if r.closingSet {
		edits = append(edits, core.RemotePreferenceEdit{ClosePrograms: &core.RemoteCloseProgramsEdit{Programs: r.closing}})
	}
	return edits
}

// beginSave writes the drafts against the preferences they were made on. Stale preferences are
// read again first; the caller tries again once that read is taken.
func (r *remotePreferencesState) beginSave() bool {
	if !r.available() || !r.loaded || r.stale || r.busy() || r.drafts() == 0 {
		return false
	}
	r.saveSource, r.saveEdits = r.source, r.edits()
	r.saveKey++
	r.saving, r.failed = true, nil
	return true
}

// keepChanged drops the drafts the preferences just read already hold.
func (r *remotePreferencesState) keepChanged() {
	stored := r.source.Saved.State.Preferences
	if r.programSet && sameString(r.program, stored.SSHProgram) {
		r.program, r.programSet = nil, false
	}
	if r.limitSet && sameUint32(r.limit, stored.ReconnectLimitSeconds) {
		r.limit, r.limitSet = nil, false
	}
	if r.reverseSet && sameBool(r.reverse, stored.AllowReverseForwarding) {
		r.reverse, r.reverseSet = nil, false
	}
	if r.closingSet && samePointer(r.closing, stored.ClosePrograms) {
		r.closing, r.closingSet = nil, false
	}
}

// take applies the page's finished requests and reports a write that failed, so the footer's
// apply stops.
func (r *remotePreferencesState) take() (saveFailed error) {
	if !r.available() {
		return nil
	}
	if source, err, ok := r.loadEffect.Take(); ok {
		r.loading = false
		if err != nil {
			r.readFailed, r.damagedPath = err, source.Saved.Path()
		} else {
			r.source, r.loaded, r.stale, r.damagedPath = source, true, false, ""
			r.keepChanged()
		}
	}
	if source, err, ok := r.saveEffect.Take(); ok {
		r.saving = false
		switch {
		case err != nil:
			// Another window may have written the file meanwhile (remoteconn.ErrConflict), Core
			// refused a value, or the first edit reached the disk before the second failed: read
			// the preferences again and keep the drafts they do not hold.
			r.failed, r.stale, saveFailed = err, true, err
		default:
			r.source, r.loaded, r.stale = source, true, false
			r.program, r.programSet, r.limit, r.limitSet = nil, false, nil, false
			r.reverse, r.reverseSet = nil, false
			r.closing, r.closingSet = nil, false
		}
	}
	return saveFailed
}

// remotePreferencesFailureMessage says why the preferences could not be read or written. A refused
// value names its field and reason; Core's other messages may name local paths and are shown, and
// the loader logs only their code.
func remotePreferencesFailureMessage(language i18n.Language, err error, path string) string {
	if field, reason, ok := core.RemoteConnectionFieldError(err); ok {
		switch {
		case field == "sshProgram" && reason == "relative":
			return i18n.Shared(language, "desktop.remoteSettings.refusedProgramRelative")
		case field == "sshProgram" && reason == "missing":
			return i18n.Shared(language, "desktop.remoteSettings.refusedProgramMissing")
		case field == "sshProgram" && reason == "notExecutable":
			return i18n.Shared(language, "desktop.remoteSettings.refusedProgramNotExecutable")
		case field == "sshProgram":
			return i18n.Shared(language, "desktop.remoteSettings.refusedProgram")
		case field == "reconnectLimitSeconds":
			return i18n.Shared(language, "desktop.remoteSettings.refusedLimit")
		}
	}
	switch {
	case errors.Is(err, remoteconn.ErrConflict):
		return i18n.Shared(language, "desktop.remoteSettings.conflict")
	case errors.Is(err, remoteconn.ErrDamaged):
		return i18n.SharedFormat(language, "desktop.remoteSettings.damaged", map[string]string{"path": path})
	case errors.Is(err, remoteconn.ErrUnavailable):
		return i18n.Shared(language, "desktop.remoteSettings.unavailable")
	}
	return i18n.SharedFormat(language, "desktop.remoteSettings.failed", map[string]string{"reason": err.Error()})
}

// declare keeps the requests that are out alive in every paint, so leaving the page does not
// cancel a write.
func (r *remotePreferencesState) declare(c ui.C) {
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
