package settingswindow

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/searchprefs"
)

// Observe the page-owned effect through frame wakes; no real user preferences are touched.
func waitSearchPage(t *testing.T, d *windowDriver, ready func() bool) {
	t.Helper()
	deadline := time.NewTimer(5 * time.Second)
	defer deadline.Stop()
	d.pump()
	for !ready() {
		select {
		case <-d.driver.Wakes():
			d.pump()
		case <-deadline.C:
			t.Fatal("search settings did not settle before the deadline")
		}
	}
}

func TestSearchPageReadsAppliesAndKeepsDraftOnConflict(t *testing.T) {
	root := filepath.Join(t.TempDir(), "preferences")
	w := newWindow(NewController(Options{SearchPreferences: searchprefs.Source{Root: root}}), Values{Language: "en", Theme: "dark"})
	w.sess.page = pageSearch
	d := openWindow(t, w)
	waitSearchPage(t, d, func() bool { return w.searchDraft.ready && !w.searchDraft.busy })
	if _, err := os.Stat(root); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("opening settings wrote a source", err)
	}
	w.searchDraft.search.SetText("32")
	w.searchDraft.replace.SetText("24")
	d.pump()
	d.click(i18n.Shared(w.marketLanguage(), "desktop.buildSettings.apply"))
	waitSearchPage(t, d, func() bool { return !w.searchDraft.busy })
	if w.searchDraft.snapshot.Effective.MaxFileBytes != 32<<20 || w.searchDraft.snapshot.Effective.ReplacementMaxFileBytes != 24<<20 {
		t.Fatalf("saved %+v", w.searchDraft.snapshot.Effective)
	}
	if err := os.WriteFile(w.searchDraft.snapshot.Path, []byte(`{"maxFileBytes":1048576}`), 0600); err != nil {
		t.Fatal(err)
	}
	w.searchDraft.search.SetText("48")
	d.pump()
	d.click(i18n.Shared(w.marketLanguage(), "desktop.buildSettings.apply"))
	waitSearchPage(t, d, func() bool { return !w.searchDraft.busy })
	if !w.searchDraft.stale || w.searchDraft.search.Text() != "48" || w.searchDraft.failure == "" {
		t.Fatal("conflict lost draft or remained writable")
	}
	d.click(i18n.Shared(w.marketLanguage(), "ui.refresh"))
	waitSearchPage(t, d, func() bool { return !w.searchDraft.busy && !w.searchDraft.stale })
	if w.searchDraft.search.Text() != "1" {
		t.Fatal("refresh did not read real source")
	}
}
