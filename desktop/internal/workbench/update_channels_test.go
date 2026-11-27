package workbench

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/buildinfo"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
)

// channelFeeds opens one fake source per channel and records every target a check read. A
// channel held by hold says on held that its check reached it, and holds it until the test
// releases it.
type channelFeeds struct {
	mu      sync.Mutex
	sources map[string]*fakeUpdateSource
	gates   map[string]chan struct{}
	held    chan updateTarget
	targets []updateTarget
}

func (f *channelFeeds) open(target updateTarget) (updateSource, error) {
	f.mu.Lock()
	f.targets = append(f.targets, target)
	source, gate, held := f.sources[target.channel], f.gates[target.channel], f.held
	f.mu.Unlock()
	if gate != nil {
		held <- target
		<-gate
	}
	if source == nil {
		return nil, errors.New("no feed for " + target.channel)
	}
	return source, nil
}

// read is the targets the checks read, in order.
func (f *channelFeeds) read() []updateTarget {
	f.mu.Lock()
	defer f.mu.Unlock()
	return slices.Clone(f.targets)
}

// hold makes the next check of channel wait for the returned release, which the test's end
// calls too, so no check stays blocked. reached waits, at most five seconds, for the check to
// get there; nothing wakes the window while it waits, so the harness's await cannot see it.
func (f *channelFeeds) hold(t *testing.T, channel string) (reached func(), release func()) {
	gate := make(chan struct{})
	f.mu.Lock()
	if f.gates == nil {
		f.gates = map[string]chan struct{}{}
	}
	f.gates[channel] = gate
	f.held = make(chan updateTarget, 1)
	held := f.held
	f.mu.Unlock()
	var once sync.Once
	release = func() {
		once.Do(func() {
			f.mu.Lock()
			delete(f.gates, channel)
			f.mu.Unlock()
			close(gate)
		})
	}
	t.Cleanup(release)
	reached = func() {
		t.Helper()
		deadline := time.NewTimer(5 * time.Second)
		defer deadline.Stop()
		select {
		case <-held:
		case <-deadline.C:
			t.Fatalf("no check of %s reached its feed", channel)
		}
	}
	return reached, release
}

// newChannelHarness is a build packaged for installed, running version, whose feeds feeds opens.
func newChannelHarness(t *testing.T, installed, version string, feeds *channelFeeds) *harness {
	t.Helper()
	h := newUpdateHarness(t, &fakeUpdateSource{})
	h.app.version = version
	openUpdateSource(h, installed, feeds.open)
	return h
}

// readSettings is the settings file as JSON values, to see the keys it holds.
func readSettings(t *testing.T, path string) map[string]json.RawMessage {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	var values map[string]json.RawMessage
	if err := json.Unmarshal(data, &values); err != nil {
		t.Fatalf("decode %s: %v", path, err)
	}
	return values
}

func TestReleaseBaseDropsTheAutoBuildSuffix(t *testing.T) {
	for version, want := range map[string]string{
		"0.8.0-autobuild.20261115120000": "0.8.0",
		"0.8.0+commit.abc":               "0.8.0",
		"0.8.0":                          "0.8.0",
		"":                               updateFromAnyVersion,
		"-autobuild":                     updateFromAnyVersion,
	} {
		if got := releaseBase(version); got != want {
			t.Errorf("releaseBase(%q) = %q, want %q", version, got, want)
		}
	}
}

// TestSwitchingToAutoBuildReadsItsFeedInFull switches a stable build to AutoBuild: the check
// reads AutoBuild's feed compared with 0.0.0, so its latest build is offered although semantic
// versioning orders it before the stable release; the build is a full install, never a patch
// from another channel's release, and the choice is saved. Switching back reads stable's feed
// against the running version again.
func TestSwitchingToAutoBuildReadsItsFeedInFull(t *testing.T) {
	feeds := &channelFeeds{sources: map[string]*fakeUpdateSource{
		buildinfo.ChannelStable:    {feed: deltaFeed("0.7.1", "0.7.0")},
		buildinfo.ChannelAutoBuild: {feed: deltaFeed("0.7.0-autobuild.20261115120000", "0.7.0")},
	}}
	h := newChannelHarness(t, buildinfo.ChannelStable, "0.7.0", feeds)
	a := h.app

	a.setUpdateChannel(buildinfo.ChannelAutoBuild, false, false)
	h.await("AutoBuild's build", func() bool { return a.updateStatus().Available == "0.7.0-autobuild.20261115120000" })
	want := updateTarget{channel: buildinfo.ChannelAutoBuild, feedURL: buildinfo.DefaultFeedURL(buildinfo.ChannelAutoBuild), against: updateFromAnyVersion, cross: true}
	if read := feeds.read(); len(read) != 1 || read[0] != want {
		t.Fatalf("the switch read %+v, want only %+v", read, want)
	}
	if status := a.updateStatus(); !status.Cross || status.Delta || status.Channel != buildinfo.ChannelAutoBuild || status.Waiting != "" {
		t.Fatalf("after the switch the status is %+v, want a full install from AutoBuild", status)
	}
	if saved := savedSettings(t, h); saved.UpdateChannel != buildinfo.ChannelAutoBuild || saved.UpdateReturnNow || saved.UpdateRestore {
		t.Fatalf("saved channel %q (now %v, restore %v), want AutoBuild alone", saved.UpdateChannel, saved.UpdateReturnNow, saved.UpdateRestore)
	}

	a.setUpdateChannel(buildinfo.ChannelStable, false, false)
	h.await("stable's release", func() bool { return a.updateStatus().Available == "0.7.1" })
	want = updateTarget{channel: buildinfo.ChannelStable, feedURL: buildinfo.DefaultFeedURL(buildinfo.ChannelStable), against: "0.7.0"}
	if read := feeds.read(); len(read) != 2 || read[1] != want {
		t.Fatalf("switching back read %+v, want %+v last", read, want)
	}
	if status := a.updateStatus(); status.Cross || !status.Delta || status.Channel != buildinfo.ChannelStable {
		t.Fatalf("back on stable the status is %+v, want the patch from 0.7.0 offered again", status)
	}
	if saved := savedSettings(t, h); saved.UpdateChannel != "" {
		t.Fatalf("back on the installed channel the saved channel is %q, want none", saved.UpdateChannel)
	}
}

// TestAutoBuildBackToStableWaitsOrSwitchesNow takes an AutoBuild build back to stable: waiting
// compares stable's feed with the release the build is on its way to and says so while
// nothing is past it; now compares it with 0.0.0, so stable's latest release is offered
// although it is older, and that choice outlives a restart.
func TestAutoBuildBackToStableWaitsOrSwitchesNow(t *testing.T) {
	stable := &fakeUpdateSource{}
	feeds := &channelFeeds{sources: map[string]*fakeUpdateSource{buildinfo.ChannelStable: stable}}
	h := newChannelHarness(t, buildinfo.ChannelAutoBuild, "0.8.0-autobuild.20261115120000", feeds)
	a := h.app

	a.setUpdateChannel(buildinfo.ChannelStable, false, false)
	h.await("the waiting check", func() bool { return a.updateStatus().UpToDate })
	if read := feeds.read(); len(read) != 1 || read[0].against != "0.8.0" || !read[0].cross || !read[0].waits() {
		t.Fatalf("waiting read %+v, want stable's feed against 0.8.0", read)
	}
	if status := a.updateStatus(); status.Waiting != "0.8.0" || status.Available != "" {
		t.Fatalf("waiting shows %+v, want it waiting for a release past 0.8.0", status)
	}

	stable.offer(updateFeed("0.7.2"))
	a.setUpdateChannel(buildinfo.ChannelStable, true, false)
	h.await("stable's latest release", func() bool { return a.updateStatus().Available == "0.7.2" })
	if read := feeds.read(); len(read) != 2 || read[1].against != updateFromAnyVersion || read[1].waits() {
		t.Fatalf("switching now read %+v, want stable's feed against 0.0.0 last", read)
	}
	if status := a.updateStatus(); status.Waiting != "" || !status.Cross {
		t.Fatalf("switching now shows %+v, want stable's release offered in full", status)
	}
	saved := savedSettings(t, h)
	if saved.UpdateChannel != buildinfo.ChannelStable || !saved.UpdateReturnNow {
		t.Fatalf("saved channel %q now %v, want stable at once", saved.UpdateChannel, saved.UpdateReturnNow)
	}
	if restarted := newUpdater(saved); !restarted.returnNow || restarted.chosen != buildinfo.ChannelStable {
		t.Fatalf("after a restart the updater has chosen %q now %v, want the switch as it was", restarted.chosen, restarted.returnNow)
	}
}

// TestSwitchDuringACheckReadsTheNewChannel switches while the check of the old channel is
// under way: what it found is dropped and the new channel is read.
func TestSwitchDuringACheckReadsTheNewChannel(t *testing.T) {
	feeds := &channelFeeds{sources: map[string]*fakeUpdateSource{
		buildinfo.ChannelStable:    {feed: updateFeed("0.7.1")},
		buildinfo.ChannelAutoBuild: {feed: updateFeed("0.7.0-autobuild.20261115120000")},
	}}
	h := newChannelHarness(t, buildinfo.ChannelStable, "0.7.0", feeds)
	a := h.app
	reached, release := feeds.hold(t, buildinfo.ChannelStable)

	a.checkForUpdates(true)
	reached()
	a.setUpdateChannel(buildinfo.ChannelAutoBuild, false, false)
	release()
	h.await("AutoBuild's build", func() bool { return a.updateStatus().Available == "0.7.0-autobuild.20261115120000" })
	read := feeds.read()
	if len(read) != 2 || read[0].channel != buildinfo.ChannelStable || read[1].channel != buildinfo.ChannelAutoBuild {
		t.Fatalf("the checks read %+v, want stable then AutoBuild", read)
	}
}

// TestSkippedVersionShowsNoArrowOrNotice skips a version: the automatic check finding it says
// nothing and shows no arrow, and a newer version is announced with a button that opens the
// update dialog.
func TestSkippedVersionShowsNoArrowOrNotice(t *testing.T) {
	source := &fakeUpdateSource{feed: updateFeed("0.8.0")}
	h := newUpdateHarness(t, source)
	a := h.app

	a.checkForUpdates(true)
	h.await("the available version", func() bool { return a.updateStatus().Available == "0.8.0" })
	a.updates.announced = ""
	a.skipUpdate()
	if saved := savedSettings(t, h); saved.UpdateSkipped[buildinfo.ChannelStable] != "0.8.0" {
		t.Fatalf("saved skipped %v, want 0.8.0 for stable", saved.UpdateSkipped)
	}
	if status := a.updateStatus(); !status.Skipped || updateArrowShown(status) {
		t.Fatalf("after Skip the status is %+v, arrow %v; want it skipped and no arrow", status, updateArrowShown(status))
	}

	a.updateCheckDue()
	h.await("the automatic check", func() bool { return source.checkCount() == 2 && !a.updateStatus().Checking })
	if n := noticeCount(a, a.text.Updates.Available("0.8.0")); n != 0 {
		t.Fatalf("the skipped version was announced %d times, want never", n)
	}
	if status := a.updateStatus(); !status.Skipped || updateArrowShown(status) {
		t.Fatalf("the check found the skipped version as %+v, want it still skipped", status)
	}

	source.offer(updateFeed("0.9.0"))
	a.updateCheckDue()
	h.await("the newer version", func() bool { return a.updateStatus().Available == "0.9.0" })
	if status := a.updateStatus(); status.Skipped || !updateArrowShown(status) {
		t.Fatalf("the newer version shows %+v, want the arrow", status)
	}
	notice := a.text.Updates.Available("0.9.0")
	var entry *notification
	for _, listed := range a.notifications.list {
		if listed.text == notice {
			entry = listed
		}
	}
	if entry == nil || entry.act == nil || entry.actLabel != i18n.Shared(a.language(), "desktop.updates.viewChanges") {
		t.Fatalf("the notice of 0.9.0 is %+v, want it with View Changes", entry)
	}
	a.notificationAct(entry.act)
	if !a.updates.dialog {
		t.Fatal("View Changes did not open the update dialog")
	}
	a.closeUpdateDialog()
	if a.updates.dialog || !updateArrowShown(a.updateStatus()) {
		t.Fatal("Later closed the dialog without leaving the arrow")
	}
}

// TestUpdateNotesAreReadBesideTheFeed finds a version: its notes are read from beside the
// feed, and shown once their first line names that version.
func TestUpdateNotesAreReadBesideTheFeed(t *testing.T) {
	source := &fakeUpdateSource{feed: updateFeed("0.8.0")}
	h := newUpdateHarness(t, source)
	a := h.app
	var mu sync.Mutex
	var asked []string
	replaceUpdateNotes(t, func(_ context.Context, address string, _ int64) ([]byte, error) {
		mu.Lock()
		asked = append(asked, address)
		mu.Unlock()
		return []byte("<!-- lithe-update-notes version=0.8.0 -->\n## Fixed\n\n- Faster start\n"), nil
	})

	a.checkForUpdates(true)
	h.await("the notes", func() bool { return a.updateStatus().Notes != "" })
	if status := a.updateStatus(); status.Notes != "## Fixed\n\n- Faster start" || status.NotesLoading {
		t.Fatalf("the notes read %q (loading %v), want the body after the header", status.Notes, status.NotesLoading)
	}
	mu.Lock()
	defer mu.Unlock()
	want := strings.TrimSuffix(buildinfo.DefaultFeedURL(buildinfo.ChannelStable), ".json") + ".notes.md"
	if len(asked) != 1 || asked[0] != want {
		t.Fatalf("read the notes from %v, want %s once", asked, want)
	}
}

func TestUpdateNotesBodyNeedsItsVersion(t *testing.T) {
	header := "<!-- lithe-update-notes version=0.8.0 -->\n"
	if body, err := updateNotesBody([]byte("\ufeff"+header+"\nHello\n"), "0.8.0"); err != nil || body != "Hello" {
		t.Fatalf("notes with a byte order mark read %q, %v; want Hello", body, err)
	}
	for name, data := range map[string]string{
		"another version": "<!-- lithe-update-notes version=0.7.9 -->\nOld",
		"no header":       "Hello",
		"open header":     "<!-- lithe-update-notes version=0.8.0\nHello",
	} {
		if body, err := updateNotesBody([]byte(data), "0.8.0"); err == nil {
			t.Errorf("%s: read %q, want an error", name, body)
		}
	}
	long := header + strings.Repeat("a", updateNotesLimit-1) + "界"
	body, err := updateNotesBody([]byte(long), "0.8.0")
	if err != nil || !strings.HasSuffix(body, "a\n\n…") || len(body) != updateNotesLimit-1+len("\n\n…") {
		t.Fatalf("long notes read %d bytes ending %q, %v; want the cut character dropped and an ellipsis", len(body), body[max(0, len(body)-8):], err)
	}
	for feed, want := range map[string]string{
		"https://example.com/feeds/stable.json":     "https://example.com/feeds/stable.notes.md",
		"https://example.com/feeds/stable.json?x=1": "https://example.com/feeds/stable.notes.md?x=1",
		"https://example.com/feeds/autobuild":       "https://example.com/feeds/autobuild.notes.md",
	} {
		if got, err := updateNotesURL(feed); err != nil || got != want {
			t.Errorf("updateNotesURL(%q) = %q, %v; want %q", feed, got, err, want)
		}
	}
}

// TestUpdateSourceIsSavedAndRead sets stable's feed: an address that is not https is refused,
// a valid one is saved and read at once, and the default address puts the channel back.
func TestUpdateSourceIsSavedAndRead(t *testing.T) {
	feeds := &channelFeeds{sources: map[string]*fakeUpdateSource{buildinfo.ChannelStable: {feed: updateFeed("0.7.1")}}}
	h := newChannelHarness(t, buildinfo.ChannelStable, "0.7.0", feeds)
	a := h.app
	mirror := "https://mirror.example.com/lithe/stable.json"

	a.setUpdateSource(buildinfo.ChannelStable, "http://mirror.example.com/stable.json")
	if saved := savedSettings(t, h); len(saved.UpdateSources) != 0 || len(feeds.read()) != 0 {
		t.Fatalf("an http feed was saved as %v and read %d times, want it refused", saved.UpdateSources, len(feeds.read()))
	}

	a.setUpdateSource(buildinfo.ChannelStable, "  "+mirror+" ")
	h.await("the mirror's release", func() bool { return a.updateStatus().Available == "0.7.1" })
	if read := feeds.read(); len(read) != 1 || read[0].feedURL != mirror {
		t.Fatalf("the mirror read %+v, want %s", read, mirror)
	}
	if saved := savedSettings(t, h); saved.UpdateSources[buildinfo.ChannelStable] != mirror {
		t.Fatalf("saved feeds %v, want the mirror for stable", saved.UpdateSources)
	}
	if sources := a.updateStatus().Sources; len(sources) != 2 || sources[0].URL != mirror || !sources[0].Custom {
		t.Fatalf("the page lists %+v, want the mirror first and marked as set", sources)
	}

	a.setUpdateSource(buildinfo.ChannelStable, buildinfo.DefaultFeedURL(buildinfo.ChannelStable))
	h.await("the default feed's check", func() bool { return len(feeds.read()) == 2 && !a.updateStatus().Checking })
	if saved := savedSettings(t, h); len(saved.UpdateSources) != 0 {
		t.Fatalf("the default address saved feeds %v, want none", saved.UpdateSources)
	}
}

// TestNoSwitchDuringADownload starts a download: neither the channel nor a feed changes until
// it ends.
func TestNoSwitchDuringADownload(t *testing.T) {
	installFakes(t)
	feeds := &channelFeeds{sources: map[string]*fakeUpdateSource{buildinfo.ChannelStable: {feed: updateFeed("0.7.1")}}}
	h := newChannelHarness(t, buildinfo.ChannelStable, "0.7.0", feeds)
	a := h.app

	a.checkForUpdates(true)
	h.await("the available version", func() bool { return a.updateStatus().Available == "0.7.1" })
	a.updateNow()
	h.await("the download", func() bool { return a.updateStatus().Downloading })
	a.setUpdateChannel(buildinfo.ChannelAutoBuild, false, false)
	a.setUpdateSource(buildinfo.ChannelStable, "https://mirror.example.com/stable.json")
	if status := a.updateStatus(); status.Channel != buildinfo.ChannelStable || !status.Downloading || status.Sources[0].Custom {
		t.Fatalf("during the download the status became %+v, want it unchanged", status)
	}
	if read := feeds.read(); len(read) != 1 {
		t.Fatalf("read %d feeds during the download, want none after the first", len(read))
	}
	a.cancelUpdate()
	h.await("the cancelled download", func() bool { return !a.updateStatus().Downloading })
}

// TestSwitchInstallKeepsAndRestoresSettings installs AutoBuild's build with Restore on: the
// settings stable leaves are kept, the copy kept when Lithe last left AutoBuild is named for
// the next launch, and that launch, once it is the AutoBuild build, restores it with the
// update settings it has now and without the switch.
func TestSwitchInstallKeepsAndRestoresSettings(t *testing.T) {
	fakes := installFakes(t)
	build := "0.8.0-autobuild.20261115120000"
	feeds := &channelFeeds{sources: map[string]*fakeUpdateSource{
		buildinfo.ChannelAutoBuild: {feed: updateFeed(build), archive: updateFile(t, "lithe.zip")},
	}}
	h := newChannelHarness(t, buildinfo.ChannelStable, "0.7.0", feeds)
	a := h.app
	kept := filepath.Join(h.store.Dir(), updateSnapshotsDir)
	if err := os.MkdirAll(kept, 0o700); err != nil {
		t.Fatal(err)
	}
	earlier := "autobuild-0.7.0-autobuild.20261101000000-20261101000000.json"
	if err := os.WriteFile(filepath.Join(kept, earlier), []byte(`{"theme":"light","updateChannel":"stable","updatesManual":false,"fromAutoBuild":true}`), 0o600); err != nil {
		t.Fatal(err)
	}
	snapshots := a.updateSnapshots()
	a.updates.mu.Lock()
	a.updates.snapshots = snapshots
	a.updates.mu.Unlock()
	if restorable := a.updateStatus().Restorable; !slices.Equal(restorable, []string{buildinfo.ChannelAutoBuild}) {
		t.Fatalf("restorable channels are %v, want AutoBuild", restorable)
	}
	a.setAutoCheckUpdates(false)

	a.setUpdateChannel(buildinfo.ChannelAutoBuild, false, true)
	h.await("AutoBuild's build", func() bool { return a.updateStatus().Available == build })
	a.updateNow()
	h.await("the install", func() bool {
		_, _, installs, _, _ := fakes.state()
		return len(installs) == 1
	})

	var left string
	for _, name := range updateSnapshotFiles(kept) {
		if strings.HasPrefix(name, "stable-0.7.0-") {
			left = name
		}
	}
	if left == "" {
		t.Fatalf("no copy of the settings stable left is kept in %v", updateSnapshotFiles(kept))
	}
	if values := readSettings(t, filepath.Join(kept, left)); string(values["theme"]) != `"dark"` || string(values["updateChannel"]) != `"autobuild"` {
		t.Fatalf("the kept copy is %v, want the settings as stable left them", values)
	}
	var pending pendingRestore
	if data, err := os.ReadFile(filepath.Join(kept, pendingRestoreFile)); err != nil || json.Unmarshal(data, &pending) != nil {
		t.Fatalf("no restore is named for the next launch: %v", err)
	}
	if pending != (pendingRestore{Channel: buildinfo.ChannelAutoBuild, Version: build, Snapshot: earlier}) {
		t.Fatalf("the next launch restores %+v, want %s for %s", pending, earlier, build)
	}

	if restored, err := restorePendingSettings(h.store, buildinfo.ChannelAutoBuild, build); !restored || err != nil {
		t.Fatalf("the AutoBuild launch restored %v, %v; want the copy", restored, err)
	}
	values := readSettings(t, h.store.Path(settingsFile))
	if string(values["theme"]) != `"light"` || string(values["fromAutoBuild"]) != "true" {
		t.Fatalf("restored %v, want AutoBuild's copy", values)
	}
	if string(values["updatesManual"]) != "true" {
		t.Fatalf("restored update settings %v, want the current ones", values)
	}
	for _, key := range updateChannelKeys {
		if _, ok := values[key]; ok {
			t.Fatalf("restored %s = %s, want the switch dropped", key, values[key])
		}
	}
	if !gone(filepath.Join(kept, pendingRestoreFile)) {
		t.Fatal("the restore is still named after the launch that did it")
	}
}

// TestPendingRestoreIsOnlyForItsBuild launches another build than the restore was named for:
// nothing is restored, and the restore is forgotten.
func TestPendingRestoreIsOnlyForItsBuild(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	kept := filepath.Join(h.store.Dir(), updateSnapshotsDir)
	if err := os.MkdirAll(kept, 0o700); err != nil {
		t.Fatal(err)
	}
	snapshot := "autobuild-0.7.0-20261101000000.json"
	if err := os.WriteFile(filepath.Join(kept, snapshot), []byte(`{"theme":"light"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	marker, _ := json.Marshal(pendingRestore{Channel: buildinfo.ChannelAutoBuild, Version: "0.9.0-autobuild.1", Snapshot: snapshot})
	if err := os.WriteFile(filepath.Join(kept, pendingRestoreFile), marker, 0o600); err != nil {
		t.Fatal(err)
	}
	before, _ := os.ReadFile(h.store.Path(settingsFile))

	if restored, err := restorePendingSettings(h.store, buildinfo.ChannelAutoBuild, "0.8.0-autobuild.1"); restored || err != nil {
		t.Fatalf("another build restored %v, %v; want nothing", restored, err)
	}
	if after, _ := os.ReadFile(h.store.Path(settingsFile)); string(after) != string(before) {
		t.Fatalf("the settings became %s, want them untouched", after)
	}
	if !gone(filepath.Join(kept, pendingRestoreFile)) {
		t.Fatal("the restore for another build is still named")
	}
}

// TestKeptSettingsArePruned keeps the newest copies and the one a restore is about to use.
func TestKeptSettingsArePruned(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	a := h.app
	kept := a.updateSnapshotStore()
	oldest := "autobuild-0.6.0-20261001000000.json"
	names := []string{oldest}
	for day := 1; day <= 7; day++ {
		names = append(names, "stable-0.7.0-2026110"+string(rune('0'+day))+"000000.json")
	}
	for _, name := range append(names, "notes.txt") {
		if err := kept.WriteFile(name, []byte("{}")); err != nil {
			t.Fatal(err)
		}
	}

	a.pruneUpdateSnapshots(context.Background(), kept, oldest)
	want := []string{names[7], names[6], names[5], names[4], names[3], oldest}
	if left := updateSnapshotFiles(kept.Dir()); !slices.Equal(left, want) {
		t.Fatalf("kept %v, want %v", left, want)
	}
	if gone(kept.Path("notes.txt")) {
		t.Fatal("pruning deleted a file that is not a kept copy")
	}
}
