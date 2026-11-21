package settingswindow

import (
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
)

// The Build pages keep their edits as drafts until the footer's Apply or OK writes them, as
// in docs/design/build-execution-settings.html: the machine's toolchain defaults, then the
// project's, then the trusted locations, the remote trust records and the remote workspace
// preferences, then each debugger's stepping policy. One request is
// out at a time, because the toolchain scopes and the trusted locations share one writer and
// every write is read back before the next. A failed write stops the rest and keeps the window
// open with its drafts; Cancel writes nothing.

const (
	applyToolchain   = "toolchain:"
	applyLocations   = "locations:"
	applyRemoteTrust = "remote-trust:"
	applyRemotePrefs = "remote-preferences:"
	applyStepping    = "stepping:"
)

// buildApply is the footer's write of the Build drafts. Only the window thread uses it.
type buildApply struct {
	// steps are the writes still to start, running the one whose request is out.
	steps   []string
	running string
	// closing says OK started the write, so the window closes after it.
	closing bool
	// failed is the error of the write that stopped the last apply.
	failed error
}

func (a *buildApply) active() bool { return a.running != "" || len(a.steps) > 0 }

// buildDrafts counts the Build pages' unapplied edits and names where Apply writes them.
func (w *window) buildDrafts(language i18n.Language) (count int, targets []string) {
	if t := w.toolchains; t.available() {
		for _, name := range t.order {
			n := t.drafts(name)
			if n == 0 {
				continue
			}
			count += n
			if name == scopeGlobal {
				targets = append(targets, i18n.Shared(language, "desktop.buildSettings.targetGlobal"))
			} else {
				targets = append(targets, i18n.Shared(language, "desktop.buildSettings.targetProject"))
			}
		}
		if n := t.locations.drafts(); n > 0 {
			count += n
			targets = append(targets, i18n.Shared(language, "desktop.trustedLocations.target"))
		}
		if n := t.remote.drafts(); n > 0 {
			count += n
			targets = append(targets, i18n.Shared(language, "desktop.trustedLocations.remoteTarget"))
		}
		if n := t.prefs.drafts(); n > 0 {
			count += n
			targets = append(targets, i18n.Shared(language, "desktop.remoteSettings.target"))
		}
	}
	if pending := w.steppingPending(); len(pending) > 0 {
		count += len(pending)
		targets = append(targets, i18n.Shared(language, "desktop.buildSettings.targetStepping"))
	}
	return count, targets
}

// startApply queues every Build draft for writing; close says OK asked for it. With nothing
// to write, OK closes the window at once.
func (w *window) startApply(close bool) {
	a := &w.apply
	if a.active() {
		a.closing = a.closing || close
		return
	}
	a.failed = nil
	if t := w.toolchains; t.available() {
		for _, name := range t.order {
			if t.drafts(name) > 0 {
				a.steps = append(a.steps, applyToolchain+name)
			}
		}
		if t.locations.drafts() > 0 {
			// The apply reads a stale list again before it writes; a failed read stops it, and
			// the next apply tries the read again.
			t.locations.readFailed = nil
			a.steps = append(a.steps, applyLocations)
		}
		if t.remote.drafts() > 0 {
			t.remote.readFailed = nil
			a.steps = append(a.steps, applyRemoteTrust)
		}
		if t.prefs.drafts() > 0 {
			t.prefs.readFailed = nil
			a.steps = append(a.steps, applyRemotePrefs)
		}
	}
	for _, id := range w.steppingPending() {
		a.steps = append(a.steps, applyStepping+id)
	}
	if !a.active() {
		// Nothing to write: OK closes at once, Apply has nothing to do.
		if close && w.sess.accept() {
			w.closeNative()
		}
		return
	}
	a.closing = close
	w.advanceApply(nil, steppingResult{})
}

// steppingResult is what steppingState.take returned in this paint.
type steppingResult struct {
	done bool
	err  error
}

// advanceApply runs after the background work was taken: it lets the request out finish,
// stops at a failure and starts the next write. Writes wait for any read that is out.
func (w *window) advanceApply(toolchainFailed error, stepping steppingResult) {
	a := &w.apply
	if !a.active() {
		return
	}
	switch {
	case strings.HasPrefix(a.running, applyToolchain):
		if toolchainFailed != nil {
			w.stopApply(toolchainFailed)
			return
		}
		if w.toolchains.saving {
			return
		}
	case a.running == applyLocations:
		if toolchainFailed != nil {
			w.stopApply(toolchainFailed)
			return
		}
		if w.toolchains.locations.saving {
			return
		}
	case a.running == applyRemoteTrust:
		if toolchainFailed != nil {
			w.stopApply(toolchainFailed)
			return
		}
		if w.toolchains.remote.saving {
			return
		}
	case a.running == applyRemotePrefs:
		if toolchainFailed != nil {
			w.stopApply(toolchainFailed)
			return
		}
		if w.toolchains.prefs.saving {
			return
		}
	case strings.HasPrefix(a.running, applyStepping):
		if !stepping.done {
			return
		}
		if stepping.err != nil {
			w.stopApply(stepping.err)
			return
		}
	}
	a.running = ""
	for len(a.steps) > 0 {
		step := a.steps[0]
		if name, ok := strings.CutPrefix(step, applyToolchain); ok {
			if w.toolchains.busy() {
				return
			}
			a.steps = a.steps[1:]
			if w.toolchains.beginSave(name) {
				a.running = step
				return
			}
			continue
		}
		if step == applyLocations {
			locations := w.toolchains.locations
			if w.toolchains.busy() {
				return
			}
			if !locations.loaded || locations.stale {
				// An earlier write in this apply changed the catalog file: read it again and
				// write the changes against what it holds now.
				if locations.readFailed != nil {
					w.stopApply(locations.readFailed)
					return
				}
				locations.beginLoad()
				return
			}
			a.steps = a.steps[1:]
			if locations.beginSave() {
				a.running = step
				return
			}
			continue
		}
		if step == applyRemoteTrust {
			remote := w.toolchains.remote
			if remote.busy() {
				return
			}
			if !remote.loaded || remote.stale {
				// A write failed and left the records stale: read them again and write the removals
				// that still name a record.
				if remote.readFailed != nil {
					w.stopApply(remote.readFailed)
					return
				}
				remote.beginLoad()
				return
			}
			a.steps = a.steps[1:]
			if remote.beginSave() {
				a.running = step
				return
			}
			continue
		}
		if step == applyRemotePrefs {
			prefs := w.toolchains.prefs
			if prefs.busy() {
				return
			}
			if !prefs.loaded || prefs.stale {
				// A write failed and left the preferences stale: read them again and write the
				// drafts they do not hold.
				if prefs.readFailed != nil {
					w.stopApply(prefs.readFailed)
					return
				}
				prefs.beginLoad()
				return
			}
			a.steps = a.steps[1:]
			if prefs.beginSave() {
				a.running = step
				return
			}
			continue
		}
		a.steps = a.steps[1:]
		if w.beginSteppingApply(strings.TrimPrefix(step, applyStepping)) {
			a.running = step
			return
		}
	}
	closing := a.closing
	a.closing = false
	if closing && w.sess.accept() {
		w.closeNative()
	}
}

// stopApply ends the apply at a failed write: the rest stays as drafts and the window stays
// open, so the failure shows beside what caused it.
func (w *window) stopApply(err error) {
	w.apply = buildApply{failed: err}
}
