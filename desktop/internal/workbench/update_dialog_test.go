package workbench

import (
	"context"
	"slices"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/buildinfo"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/settingswindow"
	"github.com/vivaui/viva/gfx"
)

// replaceOpenURL records the addresses the window opens in the browser until the test ends.
// The window opens them on its own thread, which is the test's.
func replaceOpenURL(t *testing.T) *[]string {
	t.Helper()
	var opened []string
	previous := openURL
	openURL = func(address string) error { opened = append(opened, address); return nil }
	t.Cleanup(func() { openURL = previous })
	return &opened
}

// format is key filled with values in the window's language.
func (h *harness) format(key string, values map[string]string) string {
	return i18n.SharedFormat(h.app.language(), key, values)
}

// controlNamed reports whether a control, not a label, of the last frame is named label.
func (h *harness) controlNamed(label string) bool {
	return slices.ContainsFunc(h.driver.Snapshot().Hits, func(hit gfx.Hit) bool { return hit.Label == label && !hit.IsLabel })
}

// controlContaining reports whether a control of the last frame has text in its name.
func (h *harness) controlContaining(text string) bool {
	return slices.ContainsFunc(h.driver.Snapshot().Hits, func(hit gfx.Hit) bool { return !hit.IsLabel && strings.Contains(hit.Label, text) })
}

// clickLabeled clicks the control named label and paints what it did.
func (h *harness) clickLabeled(label string) {
	h.t.Helper()
	h.click(center(h.hitLabeled(label)))
}

// availableHarness is a window that checked and found version, with the notes of it that
// notes fetches, settled once the notes were read.
func availableHarness(t *testing.T, feed *updateFeedSpec) (*harness, *fakeUpdateSource) {
	t.Helper()
	source := &fakeUpdateSource{feed: updateFeed(feed.version)}
	source.feed.Latest.NotesURL = feed.notesURL
	h := newUpdateHarness(t, source)
	if feed.notes != "" {
		replaceUpdateNotes(t, func(context.Context, string, int64) ([]byte, error) {
			return []byte(updateNotesHeader + feed.version + " -->\n" + feed.notes), nil
		})
	}
	h.app.checkForUpdates(true)
	h.await("the available version and its notes", func() bool {
		status := h.app.updateStatus()
		return status.Available == feed.version && !status.NotesLoading
	})
	h.settle()
	return h, source
}

// updateFeedSpec is the version a test's feed offers, the page of its notes and the notes.
type updateFeedSpec struct {
	version, notesURL, notes string
}

// TestUpdateArrowShowsTheChangesBeforeAnyDownload clicks the green arrow on the start screen:
// the dialog opens with what the version changed and downloads nothing; Full Notes opens the
// notes' page, Later closes the dialog and leaves the arrow, and Skip hides the arrow and keeps
// the version skipped.
func TestUpdateArrowShowsTheChangesBeforeAnyDownload(t *testing.T) {
	h, source := availableHarness(t, &updateFeedSpec{
		version:  "0.8.0",
		notesURL: "https://github.com/1lck/Lithe-IDEA/releases/tag/desktop-v0.8.0",
		notes:    "## Fixed\n\n- Faster start\n",
	})
	a := h.app
	opened := replaceOpenURL(t)
	arrow := h.format("desktop.updates.arrow.available", map[string]string{"version": "0.8.0"})
	title := h.format("desktop.updates.dialog.title", map[string]string{"version": "0.8.0"})

	h.clickLabeled(arrow)
	if !a.updates.dialog || !h.shows(title) {
		t.Fatalf("the arrow opened the dialog %v, title shown %v; want the dialog of 0.8.0", a.updates.dialog, h.shows(title))
	}
	if !h.controlContaining("Faster start") {
		t.Fatal("the dialog does not show the notes of 0.8.0")
	}
	if full, patch := source.downloadCounts(); full+patch != 0 {
		t.Fatalf("opening the dialog downloaded %d archives and %d patches, want nothing before Download", full, patch)
	}

	h.clickLabeled(h.shared("desktop.updates.dialog.fullNotes"))
	if want := []string{"https://github.com/1lck/Lithe-IDEA/releases/tag/desktop-v0.8.0"}; !slices.Equal(*opened, want) {
		t.Fatalf("Full Notes opened %v, want %v", *opened, want)
	}

	h.clickLabeled(h.shared("desktop.updates.dialog.later"))
	if a.updates.dialog || h.shows(title) {
		t.Fatal("Later left the dialog open")
	}
	if !h.controlNamed(arrow) {
		t.Fatal("Later took the arrow away")
	}

	h.clickLabeled(arrow)
	h.clickLabeled(h.shared("desktop.updates.dialog.skip"))
	if status := a.updateStatus(); a.updates.dialog || !status.Skipped || h.controlNamed(arrow) {
		t.Fatalf("after Skip the dialog is %v, the status %+v, the arrow shown %v; want both gone and the version skipped",
			a.updates.dialog, status, h.controlNamed(arrow))
	}
	if saved := savedSettings(t, h); saved.UpdateSkipped[buildinfo.ChannelStable] != "0.8.0" {
		t.Fatalf("saved skipped %v, want 0.8.0 for stable", saved.UpdateSkipped)
	}
}

// TestUpdateArrowSitsOnTheTitleBarOfAProject opens a project: the arrow is on its title bar.
func TestUpdateArrowSitsOnTheTitleBarOfAProject(t *testing.T) {
	h, _ := availableHarness(t, &updateFeedSpec{version: "0.8.0"})
	h.open(t.TempDir())
	arrow := h.format("desktop.updates.arrow.available", map[string]string{"version": "0.8.0"})
	bounds := h.hitLabeled(arrow)
	if bounds.Y+bounds.Height > titleBarHeight {
		t.Fatalf("the arrow is at %+v, want it inside the %v-point title bar", bounds, titleBarHeight)
	}
	h.click(center(bounds))
	if !h.app.updates.dialog {
		t.Fatal("the title bar's arrow did not open the dialog")
	}
}

// TestUpdateDialogFollowsTheDownload starts Download from the dialog: the dialog stays with the
// download's progress and Cancel, the arrow says how far it is, and Cancel offers the version
// again.
func TestUpdateDialogFollowsTheDownload(t *testing.T) {
	cache := t.TempDir()
	saved := updateCacheDir
	updateCacheDir = func() (string, error) { return cache, nil }
	t.Cleanup(func() { updateCacheDir = saved })
	h, source := availableHarness(t, &updateFeedSpec{version: "0.8.0"})
	a := h.app
	download := h.shared("desktop.updates.dialog.download")

	a.showUpdateDialog(surfaceButton)
	h.settle()
	if !h.shows(h.shared("desktop.updates.dialog.noNotes")) {
		t.Fatal("a version without notes does not say so")
	}
	h.clickLabeled(download)
	h.await("the download's progress", func() bool {
		status := a.updateStatus()
		return status.Downloading && status.Progress == 0.25
	})
	h.settle()
	if full, _ := source.downloadCounts(); full != 1 || !a.updates.dialog {
		t.Fatalf("Download downloaded %d archives with the dialog open %v, want one with the dialog kept", full, a.updates.dialog)
	}
	if h.controlNamed(download) || h.controlNamed(h.shared("desktop.updates.dialog.skip")) {
		t.Fatal("the dialog still offers Download or Skip while downloading")
	}
	if progress := h.format("desktop.updates.arrow.downloading", map[string]string{"version": "0.8.0", "percent": "25"}); !h.controlNamed(progress) {
		t.Fatalf("the arrow is not named %q while a quarter is downloaded", progress)
	}

	h.clickLabeled(h.shared("ui.cancel"))
	h.await("the cancelled download", func() bool { return !a.updateStatus().Downloading })
	h.settle()
	if !a.updates.dialog || !h.controlNamed(download) {
		t.Fatalf("after Cancel the dialog is open %v and offers Download %v, want both", a.updates.dialog, h.controlNamed(download))
	}
}

// TestUpdateDialogOffersWhatTheStateAllows walks the footer through the states the updater
// reports: Restart under a title that says the version is ready once downloaded, no Cancel
// while a patch is applied, the downloads page for
// a build that cannot replace itself, and no Skip for a version already skipped.
func TestUpdateDialogOffersWhatTheStateAllows(t *testing.T) {
	h, _ := availableHarness(t, &updateFeedSpec{version: "0.8.0"})
	a := h.app
	opened := replaceOpenURL(t)
	a.showUpdateDialog(surfaceButton)
	show := func(change func(*settingswindow.UpdateStatus)) {
		t.Helper()
		a.changeUpdate(func(s *settingswindow.UpdateStatus) {
			s.Ready, s.Downloading, s.Applying, s.Manual, s.Skipped, s.NotesLoading = false, false, false, "", false, false
			change(s)
		})
		h.settle()
	}
	skip, download := h.shared("desktop.updates.dialog.skip"), h.shared("desktop.updates.dialog.download")

	show(func(s *settingswindow.UpdateStatus) { s.Ready = true })
	if !h.controlNamed(h.shared("desktop.updates.dialog.restart")) || h.controlNamed(download) || h.controlNamed(skip) {
		t.Fatal("a downloaded version is not offered Restart alone")
	}
	if ready := h.format("desktop.updates.arrow.ready", map[string]string{"version": "0.8.0"}); !h.controlNamed(ready) {
		t.Fatalf("the arrow is not named %q once downloaded", ready)
	}
	if title := h.format("desktop.updates.dialog.titleReady", map[string]string{"version": "0.8.0"}); !h.shows(title) {
		t.Fatalf("the dialog is not titled %q once downloaded", title)
	}

	show(func(s *settingswindow.UpdateStatus) { s.Downloading, s.Applying = true, true })
	if h.controlNamed(h.shared("ui.cancel")) || !h.controlNamed(h.shared("desktop.updates.dialog.later")) {
		t.Fatal("applying a patch offers Cancel, or no Later")
	}

	show(func(s *settingswindow.UpdateStatus) { s.Manual = "Download it by hand" })
	h.clickLabeled(h.shared("desktop.updates.dialog.downloads"))
	if want := []string{buildinfo.DownloadsURL}; !slices.Equal(*opened, want) {
		t.Fatalf("Downloads opened %v, want %v", *opened, want)
	}

	show(func(s *settingswindow.UpdateStatus) { s.Skipped = true })
	if h.controlNamed(skip) || !h.controlNamed(download) {
		t.Fatal("a skipped version opened again offers Skip, or no Download")
	}

	show(func(s *settingswindow.UpdateStatus) { s.NotesLoading = true })
	if !h.shows(h.shared("desktop.updates.dialog.notesLoading")) {
		t.Fatal("notes on the way are not said to be loading")
	}
}

// TestUpdateNotesOpenOnlyWebLinks follows the links of the notes, which are not signed: only
// web addresses open.
func TestUpdateNotesOpenOnlyWebLinks(t *testing.T) {
	h := newUpdateHarness(t, &fakeUpdateSource{})
	opened := replaceOpenURL(t)
	for _, address := range []string{
		"https://example.com/a", "http://example.com/b", "file:///etc/hosts", "javascript:alert(1)",
		"lithe://open", "https:///nohost", "",
	} {
		h.app.openUpdateNotes(address)
	}
	if want := []string{"https://example.com/a", "http://example.com/b"}; !slices.Equal(*opened, want) {
		t.Fatalf("the notes opened %v, want only %v", *opened, want)
	}
}
