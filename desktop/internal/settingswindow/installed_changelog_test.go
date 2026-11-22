package settingswindow

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/marketplace"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
)

// releaseReader is a PluginReleases that answers from answers in turn, the last one again
// once they run out, and remembers the repositories it was asked about.
type releaseReader struct {
	mu      sync.Mutex
	asked   []string
	answers []releaseAnswer
}

type releaseAnswer struct {
	releases  []PluginRelease
	supported bool
	err       error
}

func (r *releaseReader) list(_ context.Context, repository string) ([]PluginRelease, bool, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.asked = append(r.asked, repository)
	answer := r.answers[min(len(r.asked), len(r.answers))-1]
	return answer.releases, answer.supported, answer.err
}

func (r *releaseReader) reads() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]string(nil), r.asked...)
}

// fixtureReleases are a pre-release newer than the installed 1.2.3, the installed release
// with notes that link to a web page and to a file, and an old release without notes.
func fixtureReleases() []PluginRelease {
	// Noon UTC is the same date in every time zone the tests run in.
	day := func(d int) time.Time { return time.Date(2026, 11, d, 12, 0, 0, 0, time.UTC) }
	return []PluginRelease{
		{Tag: "v1.3.0-beta.1", Notes: "Tries the new layout.", Published: day(21), Prerelease: true,
			URL: "https://github.com/example/versions-fixture/releases/tag/v1.3.0-beta.1"},
		{Tag: "v1.2.3", Name: "Faster refresh", Published: day(20),
			Notes: "Reads the newest index.\n\n- See [the guide](https://example.com/guide).\n- Or [the file](file:///etc/hosts).",
			URL:   "https://github.com/example/versions-fixture/releases/tag/v1.2.3"},
		{Tag: "v1.0.0", Published: day(1), URL: "https://github.com/example/versions-fixture/releases/tag/v1.0.0"},
	}
}

// openChangelog opens the detail of detailFixture on its Changelog tab, reading releases
// from reader, once the marketplace listing is in.
func openChangelog(t *testing.T, reader *releaseReader, adjust ...func(*Options)) (*windowDriver, PluginFacts) {
	t.Helper()
	w, fact, _ := detailFixture(i18n.English, append([]func(*Options){func(opts *Options) {
		opts.PluginReleases = reader.list
	}}, adjust...)...)
	d := openWindow(t, w, func(config *app.Config) { config.Width, config.Height = 1400, 900 })
	d.until("the marketplace index", func() bool { return w.market.status == marketReady })
	d.click(i18n.Shared(i18n.English, "native.updateLog"))
	d.pump()
	return d, fact
}

// painted is where value was last painted, and whether it was.
func (d *windowDriver) painted(value string) (gfx.Rect, bool) {
	texts := d.driver.Snapshot().Texts
	for i := len(texts) - 1; i >= 0; i-- {
		if texts[i].Value == value {
			return texts[i].Bounds, true
		}
	}
	return gfx.Rect{}, false
}

// paintedOnLineOf is whether value is painted on the line of a text painted at line.
func (d *windowDriver) paintedOnLineOf(value string, line gfx.Rect) bool {
	for _, text := range d.driver.Snapshot().Texts {
		middle := text.Bounds.Y + text.Bounds.Height/2
		if text.Value == value && middle >= line.Y && middle <= line.Y+line.Height {
			return true
		}
	}
	return false
}

// TestInstalledChangelogListsTheRepositoryReleases covers the Changelog tab: it reads the
// releases of the repository the listing names, lists them newest first with their notes laid
// out in full above the next release, marks the pre-release and the installed version, follows
// only the notes' web links, and reads nothing again when the tab is shown again.
func TestInstalledChangelogListsTheRepositoryReleases(t *testing.T) {
	reader := &releaseReader{answers: []releaseAnswer{{releases: fixtureReleases(), supported: true}}}
	var opened []string
	d, _ := openChangelog(t, reader, func(opts *Options) {
		opts.OpenURL = func(address string) { opened = append(opened, address) }
	})
	d.until("the releases", func() bool { _, ok := d.painted("Faster refresh"); return ok })
	if got := reader.reads(); len(got) != 1 || got[0] != "https://github.com/example/versions-fixture" {
		t.Fatalf("the releases of %q were read, want the listing's repository once", got)
	}
	beta, _ := d.painted("v1.3.0-beta.1")
	installed, _ := d.painted("Faster refresh")
	old, ok := d.painted("v1.0.0")
	if !ok || beta.Y >= installed.Y || installed.Y >= old.Y {
		t.Fatalf("the releases are not newest first: %+v, %+v, %+v", beta, installed, old)
	}
	if !d.paintedOnLineOf(i18n.Shared(i18n.English, "desktop.pluginChangelog.prerelease"), beta) {
		t.Error("the pre-release has no pre-release badge")
	}
	if !d.paintedOnLineOf(i18n.Shared(i18n.English, "native.installed"), installed) {
		t.Error("the installed release has no installed badge")
	}
	if !d.paintedOnLineOf("v1.2.3", installed) || !d.paintedOnLineOf("2026-11-20", installed) {
		t.Error("the installed release does not show its tag and date beside its title")
	}
	if d.paintedOnLineOf(i18n.Shared(i18n.English, "desktop.pluginChangelog.prerelease"), installed) {
		t.Error("a release that is not a pre-release has the badge")
	}
	// The notes are laid out on the paint that shows them: their last line is above the
	// next release, not clipped to a first guess at their height.
	guide, ok := d.painted("the guide")
	if !ok {
		t.Fatal("the installed release's notes are not painted")
	}
	if guide.Y <= installed.Y || guide.Y+guide.Height >= old.Y {
		t.Fatalf("the notes at %+v are not between their title at %+v and the next release at %+v", guide, installed, old)
	}
	if !d.text(i18n.Shared(i18n.English, "desktop.pluginChangelog.noNotes")) {
		t.Error("the release without notes does not say so")
	}

	file, _ := d.painted("the file")
	if err := d.driver.Click(file.X+file.Width/2, file.Y+file.Height/2); err != nil {
		t.Fatal(err)
	}
	if err := d.driver.Click(guide.X+guide.Width/2, guide.Y+guide.Height/2); err != nil {
		t.Fatal(err)
	}
	d.pump()
	if len(opened) != 1 || opened[0] != "https://example.com/guide" {
		t.Fatalf("clicking the notes' links opened %q, want only the web link", opened)
	}

	d.click(i18n.Shared(i18n.English, "native.versionsSource"))
	d.pump()
	d.click(i18n.Shared(i18n.English, "native.updateLog"))
	d.pump()
	if _, ok := d.painted("Faster refresh"); !ok {
		t.Fatal("the releases are not shown again")
	}
	if got := reader.reads(); len(got) != 1 {
		t.Fatalf("showing the tab again read the releases again: %q", got)
	}
}

// TestInstalledChangelogRetriesAFailedRead covers a read that fails: the tab says so with
// the error, the failure is logged, and Retry reads again and shows the releases.
func TestInstalledChangelogRetriesAFailedRead(t *testing.T) {
	reader := &releaseReader{answers: []releaseAnswer{
		{err: errors.New("github: request failed: rate limited")},
		{releases: fixtureReleases(), supported: true},
	}}
	var logged []string
	d, _ := openChangelog(t, reader, func(opts *Options) {
		opts.SettingsError = func(operation string, err error) { logged = append(logged, operation+": "+err.Error()) }
	})
	failed := i18n.Shared(i18n.English, "desktop.pluginChangelog.failed")
	d.until("the failure", func() bool { return d.wrapped(failed) })
	if !d.wrapped("rate limited") {
		t.Error("the failure does not show its error")
	}
	if len(logged) != 1 || logged[0] != "plugin_releases: github: request failed: rate limited" {
		t.Fatalf("logged %q, want the failed read once", logged)
	}
	d.click(i18n.Shared(i18n.English, "desktop.pluginChangelog.retry"))
	d.until("the releases", func() bool { _, ok := d.painted("Faster refresh"); return ok })
	if got := reader.reads(); len(got) != 2 {
		t.Fatalf("the releases were read %d times, want twice", len(got))
	}
}

// TestInstalledChangelogSaysWhyThereAreNoReleases covers the notes in place of the list: a
// repository the reader cannot read, a repository without releases, and a listing without a
// repository, which is not read at all.
func TestInstalledChangelogSaysWhyThereAreNoReleases(t *testing.T) {
	t.Run("unsupported", func(t *testing.T) {
		d, _ := openChangelog(t, &releaseReader{answers: []releaseAnswer{{supported: false}}})
		note := i18n.Shared(i18n.English, "desktop.pluginChangelog.unsupported")
		d.until("the note", func() bool { return d.wrapped(note) })
		if !d.has("example/versions-fixture") {
			t.Error("the note does not link to the repository")
		}
	})
	t.Run("empty", func(t *testing.T) {
		d, _ := openChangelog(t, &releaseReader{answers: []releaseAnswer{{supported: true}}})
		note := i18n.Shared(i18n.English, "desktop.pluginChangelog.empty")
		d.until("the note", func() bool { return d.wrapped(note) })
		if !d.has(i18n.Shared(i18n.English, "desktop.pluginChangelog.openReleases")) {
			t.Error("the note does not link to the releases page")
		}
	})
	t.Run("no repository", func(t *testing.T) {
		reader := &releaseReader{answers: []releaseAnswer{{releases: fixtureReleases(), supported: true}}}
		d, _ := openChangelog(t, reader, func(opts *Options) {
			listing := opts.Marketplace
			opts.Marketplace = func(ctx context.Context) (marketplace.Snapshot, error) {
				snapshot, err := listing(ctx)
				snapshot.Index.Plugins = append([]core.MarketplacePlugin(nil), snapshot.Index.Plugins...)
				snapshot.Index.Plugins[0].Repository = ""
				return snapshot, err
			}
		})
		if !d.wrapped(i18n.Shared(i18n.English, "desktop.pluginChangelog.noRepository")) {
			t.Fatal("the tab does not say the listing names no repository")
		}
		if got := reader.reads(); len(got) != 0 {
			t.Fatalf("releases were read without a repository: %q", got)
		}
	})
}

// TestInstalledChangelogNeedsAReader covers a window that cannot read releases: the detail
// has no Changelog tab.
func TestInstalledChangelogNeedsAReader(t *testing.T) {
	w, _, _ := detailFixture(i18n.English)
	d := openWindow(t, w, func(config *app.Config) { config.Width, config.Height = 1400, 800 })
	d.until("the marketplace index", func() bool { return w.market.status == marketReady })
	if !d.has(i18n.Shared(i18n.English, "native.versionsSource")) {
		t.Fatal("the detail's tabs are not shown")
	}
	if d.has(i18n.Shared(i18n.English, "native.updateLog")) {
		t.Fatal("the Changelog tab is shown without a way to read releases")
	}
}

// TestInstalledTabsStayWithinANarrowDetail covers the detail's six tabs in English at the
// window's least width: they wrap onto another line rather than run past the detail's edge.
func TestInstalledTabsStayWithinANarrowDetail(t *testing.T) {
	reader := &releaseReader{answers: []releaseAnswer{{supported: true}}}
	w, _, _ := detailFixture(i18n.English, func(opts *Options) { opts.PluginReleases = reader.list })
	d := openWindow(t, w, func(config *app.Config) { config.Width, config.Height = windowMinWidth, 700 })
	d.until("the marketplace index", func() bool { return w.market.status == marketReady })
	d.pump()
	for tab := range installedTabCount {
		title := installedTabTitle(i18n.English, tab)
		hit := d.hit(title)
		if right := hit.Bounds.X + hit.Bounds.Width; right > windowMinWidth {
			t.Errorf("the %q tab ends at x=%.1f, past the window's edge at %d", title, right, windowMinWidth)
		}
	}
}
