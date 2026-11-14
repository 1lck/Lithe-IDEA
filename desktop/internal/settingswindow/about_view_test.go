package settingswindow

import (
	"errors"
	"runtime/debug"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
)

// TestAboutFactsSayWhatThisCopyIs checks the facts the About page reads: the platform as a
// person names it, the commit and day of the build when the build recorded them, the Go
// runtime, and the block copied for an issue, whose first line says a preview is one.
func TestAboutFactsSayWhatThisCopyIs(t *testing.T) {
	recorded := []debug.BuildSetting{
		{Key: "vcs.revision", Value: "0123456789abcdef"},
		{Key: "vcs.time", Value: "2026-11-13T22:15:00+08:00"},
	}
	for _, tc := range []struct {
		name  string
		in    aboutInputs
		facts aboutFacts
	}{
		{
			name: "preview",
			in: aboutInputs{version: "0.7.0", osName: "macOS", osVersion: "26.1", arch: "arm64",
				goVersion: "go1.26.1", settings: recorded},
			facts: aboutFacts{platform: "macOS · arm64", build: "0123456 · 2026-11-13", runtime: "go1.26.1",
				copy: "Lithe 0.7.0 (preview)\nplatform: macOS 26.1 · arm64\nbuild: 0123456 · 2026-11-13\nruntime: go1.26.1\n"},
		},
		{
			name: "stable",
			in: aboutInputs{version: "0.7.0", stable: true, osName: "Windows", osVersion: "11", arch: "amd64",
				goVersion: "go1.26.1", settings: recorded},
			facts: aboutFacts{platform: "Windows · x86-64", build: "0123456 · 2026-11-13", runtime: "go1.26.1",
				copy: "Lithe 0.7.0\nplatform: Windows 11 · x86-64\nbuild: 0123456 · 2026-11-13\nruntime: go1.26.1\n"},
		},
		{
			// go run and go test record no commit; the page says so rather than a blank.
			name: "unrecorded",
			in:   aboutInputs{version: "0.7.0", arch: "386", goVersion: "go1.26.1"},
			facts: aboutFacts{platform: "x86", runtime: "go1.26.1",
				copy: "Lithe 0.7.0 (preview)\nplatform: x86\nruntime: go1.26.1\n"},
		},
		{
			// A commit without a readable time keeps the commit alone.
			name: "commit only",
			in: aboutInputs{version: "0.7.0", stable: true, osName: "Linux", arch: "riscv64", goVersion: "go1.26.1",
				settings: []debug.BuildSetting{{Key: "vcs.revision", Value: "abc"}, {Key: "vcs.time", Value: "yesterday"}}},
			facts: aboutFacts{platform: "Linux · riscv64", build: "abc", runtime: "go1.26.1",
				copy: "Lithe 0.7.0\nplatform: Linux · riscv64\nbuild: abc\nruntime: go1.26.1\n"},
		},
	} {
		if got := readAboutFacts(tc.in); got != tc.facts {
			t.Errorf("%s: facts = %+v, want %+v", tc.name, got, tc.facts)
		}
	}
}

// TestAboutPageShowsThePreviewAndCopiesTheFacts opens the About page of a preview build: it
// shows the version with its preview label, its links open their pages, and Copy puts the
// facts on the clipboard and says so, or says why it could not and reports the failure.
func TestAboutPageShowsThePreviewAndCopiesTheFacts(t *testing.T) {
	saved := copyText
	t.Cleanup(func() { copyText = saved })
	var copied []string
	copyFailure := error(nil)
	copyText = func(text string) error {
		if copyFailure != nil {
			return copyFailure
		}
		copied = append(copied, text)
		return nil
	}
	type failure struct {
		operation string
		err       error
	}
	var opened []string
	var reported []failure
	w := newWindow(NewController(Options{
		Version:       "0.7.0",
		OpenURL:       func(url string) { opened = append(opened, url) },
		SettingsError: func(operation string, err error) { reported = append(reported, failure{operation, err}) },
	}), Values{})
	w.sess.page = pageAbout
	d := openWindow(t, w)
	text := func(id string) string { return i18n.Shared(i18n.English, id) }

	if !d.text("0.7.0 Preview") {
		t.Fatal("the About page does not show the version as 0.7.0 Preview")
	}
	d.click(text("desktop.settings.about.qq"))
	d.click(text("desktop.settings.about.issues"))
	if want := []string{aboutQQURL, aboutIssuesURL}; len(opened) != 2 || opened[0] != want[0] || opened[1] != want[1] {
		t.Fatalf("opened %q, want %q", opened, want)
	}

	d.click(text("desktop.settings.about.copy"))
	d.pump()
	if len(copied) != 1 || copied[0] != w.facts().copy || !d.has(text("desktop.settings.about.copied")) {
		t.Fatalf("copied %q and the button says Copied = %v, want the facts once", copied, d.has(text("desktop.settings.about.copied")))
	}

	copyFailure = errors.New("no clipboard")
	d.click(text("desktop.settings.about.copied"))
	d.pump()
	failed := i18n.SharedFormat(i18n.English, "desktop.settings.about.copyFailed", map[string]string{"reason": "no clipboard"})
	if !d.text(failed) || !d.has(text("desktop.settings.about.copy")) || len(reported) != 1 ||
		reported[0].operation != "settings_about_copy" || !errors.Is(reported[0].err, copyFailure) {
		t.Fatalf("after a failed copy the page says %q = %v and reported %v, want the reason shown and reported once as settings_about_copy", failed, d.text(failed), reported)
	}
}

// TestUpdatesPageNamesTheRunningVersionAsItIsReleased shows the running version on the Updates
// page, with the preview label unless the build is a stable release, in both the card of the
// current version and the line that says it is up to date.
func TestUpdatesPageNamesTheRunningVersionAsItIsReleased(t *testing.T) {
	for _, tc := range []struct {
		stable bool
		want   string
	}{
		{false, "0.7.0 Preview"},
		{true, "0.7.0"},
	} {
		w := newWindow(NewController(Options{
			Version: "0.7.0", Stable: tc.stable,
			UpdateStatus: func() UpdateStatus { return UpdateStatus{Configured: true, UpToDate: true} },
		}), Values{})
		w.sess.page = pageUpdates
		d := openWindow(t, w)
		upToDate := i18n.SharedFormat(i18n.English, "desktop.settings.updates.upToDate", map[string]string{"version": tc.want})
		if !d.text(tc.want) || !d.text(upToDate) {
			t.Errorf("stable = %v: the page shows %q = %v and %q = %v, want both", tc.stable, tc.want, d.text(tc.want), upToDate, d.text(upToDate))
		}
	}
}

// TestApplyingADeltaUpdateOffersNoCancel shows the update card while a download runs, which
// Cancel stops, and while the patch applies, which nothing can stop: then the card offers no
// Cancel. The window's own Cancel is there throughout, so the card's is counted against a
// version that is only available.
func TestApplyingADeltaUpdateOffersNoCancel(t *testing.T) {
	cancels := func(status UpdateStatus) int {
		w := newWindow(NewController(Options{
			Version: "0.7.0", UpdateStatus: func() UpdateStatus { return status },
		}), Values{})
		w.sess.page = pageUpdates
		d := openWindow(t, w)
		n := 0
		for _, hit := range d.driver.Snapshot().Hits {
			if hit.Label == w.text.Settings.Cancel && !hit.IsLabel && !hit.Backdrop && !hit.ID.IsZero() {
				n++
			}
		}
		return n
	}
	available := UpdateStatus{Configured: true, Available: "0.7.1", Delta: true}
	downloading, applying := available, available
	downloading.Downloading, downloading.Progress = true, 0.5
	applying.Downloading, applying.Applying, applying.Progress = true, true, 1
	base := cancels(available)
	if n := cancels(downloading); n != base+1 {
		t.Errorf("downloading the patch shows %d Cancel buttons, want the card's beside the window's %d", n, base)
	}
	if n := cancels(applying); n != base {
		t.Errorf("applying the patch shows %d Cancel buttons, want only the window's %d", n, base)
	}
}

// TestUpdateLineSaysTheStepUnderWay checks what the update row says for each state, the step
// under way first.
func TestUpdateLineSaysTheStepUnderWay(t *testing.T) {
	format := func(id string, args map[string]string) string { return i18n.SharedFormat(i18n.English, id, args) }
	text := func(id string) string { return i18n.Shared(i18n.English, id) }
	checked := time.Date(2026, 11, 14, 9, 0, 0, 0, time.UTC)
	for _, tc := range []struct {
		name   string
		status UpdateStatus
		want   string
	}{
		{"nothing yet", UpdateStatus{Configured: true}, text("desktop.settings.updates.help")},
		{"checking", UpdateStatus{Configured: true, Checking: true, UpToDate: true}, text("desktop.settings.updates.checking")},
		{"up to date", UpdateStatus{Configured: true, UpToDate: true, LastChecked: checked},
			format("desktop.settings.updates.upToDate", map[string]string{"version": "0.7.0 Preview"})},
		{"available", UpdateStatus{Configured: true, Available: "0.7.1"},
			format("desktop.settings.updates.available", map[string]string{"version": "0.7.1"})},
		{"downloading", UpdateStatus{Configured: true, Available: "0.7.1", Downloading: true, Progress: 0.426},
			format("desktop.settings.updates.downloading", map[string]string{"version": "0.7.1", "percent": "42"})},
		{"delta available", UpdateStatus{Configured: true, Available: "0.7.1", Delta: true, DeltaSize: 3 << 20, FullSize: 96 << 20},
			format("desktop.settings.updates.availableDelta", map[string]string{"version": "0.7.1", "size": "3 MB", "full": "96 MB"})},
		{"delta without sizes", UpdateStatus{Configured: true, Available: "0.7.1", Delta: true},
			format("desktop.settings.updates.available", map[string]string{"version": "0.7.1"})},
		{"downloading the delta", UpdateStatus{Configured: true, Available: "0.7.1", Delta: true, Downloading: true, Progress: 0.5},
			format("desktop.settings.updates.downloadingDelta", map[string]string{"version": "0.7.1", "percent": "50"})},
		{"applying the delta", UpdateStatus{Configured: true, Available: "0.7.1", Delta: true, Downloading: true, Applying: true, Progress: 1},
			format("desktop.settings.updates.applying", map[string]string{"version": "0.7.1"})},
		{"downloading in full after the delta failed", UpdateStatus{Configured: true, Available: "0.7.1", Downloading: true, FellBack: true, Progress: 0.1},
			format("desktop.settings.updates.downloadingFull", map[string]string{"version": "0.7.1", "percent": "10"})},
		{"ready", UpdateStatus{Configured: true, Available: "0.7.1", Ready: true},
			format("desktop.settings.updates.ready", map[string]string{"version": "0.7.1"})},
		{"installing", UpdateStatus{Configured: true, Available: "0.7.1", Ready: true, Installing: true},
			text("desktop.settings.updates.installing")},
	} {
		if got := updateLine(i18n.English, tc.status, "0.7.0 Preview"); got != tc.want {
			t.Errorf("%s: line = %q, want %q", tc.name, got, tc.want)
		}
	}
}
