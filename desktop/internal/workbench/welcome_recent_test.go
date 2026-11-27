package workbench

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/installedpackagetest"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

func (h *harness) seedRecent(entries []core.RecentProject) {
	h.t.Helper()
	if err := h.store.Save(recentFile, entries); err != nil {
		h.t.Fatal(err)
	}
	h.app.loadRecent()
}

func (h *harness) resizeWelcome() {
	h.t.Helper()
	if err := h.driver.Resize(900, 600); err != nil {
		h.t.Fatal(err)
	}
}

func welcomeRecentDir(t *testing.T, root, name string) string {
	t.Helper()
	dir := filepath.Join(root, name)
	if err := os.Mkdir(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	return dir
}

func (h *harness) pinWelcomeProject(path string) {
	h.t.Helper()
	h.rightClickRow(path)
	h.clickNamed(h.app.text.Welcome.MenuPin)
	h.settle()
}

func TestWelcomeMostRecentlyPinnedProjectMovesFirst(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	base := t.TempDir()
	older := welcomeRecentDir(t, base, "older")
	newer := welcomeRecentDir(t, base, "newer")
	h.seedRecent([]core.RecentProject{{Path: newer, LastOpenedAt: 200}, {Path: older, LastOpenedAt: 100}})
	h.resizeWelcome()
	h.pinWelcomeProject(newer)
	h.pinWelcomeProject(older)
	if h.welcomeRowHit(older).Bounds.Y >= h.welcomeRowHit(newer).Bounds.Y {
		t.Fatal("the most recently pinned project did not reach the top")
	}
	h.rightClickRow(older)
	h.clickNamed(h.app.text.Welcome.MenuUnpin)
	h.settle()
	if h.welcomeRowHit(newer).Bounds.Y >= h.welcomeRowHit(older).Bounds.Y {
		t.Fatal("unpin did not restore the pinned project's precedence")
	}
}

func TestWelcomePinSurvivesAnotherWindowOpeningAProject(t *testing.T) {
	first := newHarness(t, &testKernel{Client: core.NewClient()})
	base := t.TempDir()
	alpha := welcomeRecentDir(t, base, "alpha")
	beta := welcomeRecentDir(t, base, "beta")
	gamma := welcomeRecentDir(t, base, "gamma")
	first.seedRecent([]core.RecentProject{{Path: beta, LastOpenedAt: 200}, {Path: alpha, LastOpenedAt: 100}})
	first.resizeWelcome()
	opts := Options{Kernel: &testKernel{Client: core.NewClient()}, Store: store.At(first.store.Dir()), Languages: []string{"zh-Hans"}}
	second := newHarnessWithOptions(t, opts)
	first.pinWelcomeProject(alpha)
	second.open(gamma)
	reopened := newHarnessWithOptions(t, opts)
	reopened.resizeWelcome()
	if len(reopened.app.recent) != 3 || reopened.app.recent[0].Path != alpha || !reopened.app.recent[0].Pinned {
		t.Fatalf("the other window overwrote the pin or lost a recent record: %v", reopened.app.recent)
	}
}

func TestWelcomePinFromAnOlderWindowDoesNotReverseThePin(t *testing.T) {
	first := newHarness(t, &testKernel{Client: core.NewClient()})
	project := t.TempDir()
	first.seedRecent([]core.RecentProject{{Path: project}})
	first.resizeWelcome()
	second := newHarnessWithOptions(t, Options{
		Kernel: &testKernel{Client: core.NewClient()}, Store: store.At(first.store.Dir()), Languages: []string{"zh-Hans"},
	})
	second.resizeWelcome()
	first.pinWelcomeProject(project)
	second.pinWelcomeProject(project)
	if len(second.app.recent) != 1 || !second.app.recent[0].Pinned {
		t.Fatal("clicking Pin in an older window reversed an existing pin")
	}
}

func TestWelcomeProjectTagsCanBeEditedAndFiltered(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	base := t.TempDir()
	alpha := welcomeRecentDir(t, base, "alpha")
	beta := welcomeRecentDir(t, base, "beta")
	h.seedRecent([]core.RecentProject{{Path: alpha}, {Path: beta, Tags: []string{"Personal"}}})
	h.resizeWelcome()

	lang := h.app.language()
	h.rightClickRow(alpha)
	h.clickNamed(i18n.Shared(lang, "desktop.welcome.editTags"))
	field := h.pageHit(i18n.Shared(lang, "desktop.welcome.tagsInput"))
	h.click(center(field.Bounds))
	if err := h.driver.Type("Work, work, Research"); err != nil {
		t.Fatal(err)
	}
	h.clickNamed(i18n.Shared(lang, "ui.save"))
	h.settle()
	if !h.shows("Work, Research") {
		t.Fatal("tags did not appear on the project")
	}

	h.clickNamed(i18n.Shared(lang, "desktop.welcome.filterTags"))
	h.clickNamed("Work")
	if !h.shows("alpha") || h.shows("beta") {
		t.Fatal("the tag picker did not filter the recent projects")
	}
	var saved []core.RecentProject
	if _, err := h.store.Load(recentFile, &saved); err != nil || len(saved) != 2 || strings.Join(saved[0].Tags, ",") != "Work,Research" {
		t.Fatalf("saved project tags = %v, error = %v", saved, err)
	}
}

func TestWelcomeRemoteProjectCanBeReopenedFromHistory(t *testing.T) {
	h, _, _, _ := remoteWorkspaceHarness(t)
	p := h.openRemoteTestProject(t)
	h.app.closeProject()
	h.await("return to the welcome screen", func() bool { return h.app.project == nil })
	h.settle()
	h.resizeWelcome()

	if len(h.app.recent) != 1 {
		t.Fatalf("expected one recent remote project, got %v", h.app.recent)
	}
	entry := h.app.recent[0]
	if entry.Remote == nil || entry.Remote.Folder != remoteTestHome+"/project" ||
		entry.Path == p.root || h.app.missing[entry.Path] || !h.shows(remoteTestHost) {
		t.Fatalf("remote folder was not retained as a remote recent entry: %+v", entry)
	}
	h.clickNamed("project")
	h.await("remote project to reopen from recents", func() bool {
		return h.app.project != nil && h.app.project.remote != nil && h.app.project.remote.session != ""
	})
	h.settle()
	if len(h.app.recent) != 1 || h.app.project.root != p.root {
		t.Fatalf("reopen did not return to the same remote project: %v", h.app.recent)
	}
}

func TestRecentProjectsMigratesLegacyHistoryWithoutWritingIt(t *testing.T) {
	prefs := store.At(t.TempDir())
	project := t.TempDir()
	kernel := core.NewClient()
	if err := prefs.Save(legacyRecentFile, []core.RecentProject{{Path: project, Pinned: true}}); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	loaded, _, err := reduceStoredRecent(ctx, prefs, kernel, core.NormalizeRecent(), false)
	if err != nil || len(loaded.Entries) != 1 || !loaded.Entries[0].Pinned {
		t.Fatalf("load legacy history: %+v, %v", loaded.Entries, err)
	}
	if _, err := os.Stat(prefs.Path(recentFile)); !os.IsNotExist(err) {
		t.Fatalf("reading legacy history created the v2 file or failed: %v", err)
	}
	_, _, err = reduceStoredRecent(ctx, prefs, kernel, core.SetRecentTags(project, []string{"Work"}), true)
	if err != nil {
		t.Fatal(err)
	}
	var legacy []core.RecentProject
	if _, err := prefs.Load(legacyRecentFile, &legacy); err != nil || len(legacy) != 1 || len(legacy[0].Tags) != 0 {
		t.Fatalf("migration changed the old file: %+v, %v", legacy, err)
	}
	if err := prefs.Save(legacyRecentFile, []core.RecentProject{{Path: t.TempDir()}}); err != nil {
		t.Fatal(err)
	}
	loaded, _, err = reduceStoredRecent(ctx, prefs, kernel, core.NormalizeRecent(), false)
	if err != nil || len(loaded.Entries) != 1 || loaded.Entries[0].Path != project || len(loaded.Entries[0].Tags) != 1 {
		t.Fatalf("an old client overwrote v2 history: %+v, %v", loaded.Entries, err)
	}
	if _, _, err := reduceStoredRecent(ctx, prefs, kernel, core.RemoveRecent(project), true); err != nil {
		t.Fatal(err)
	}
	loaded, _, err = reduceStoredRecent(ctx, prefs, kernel, core.NormalizeRecent(), false)
	if err != nil || len(loaded.Entries) != 0 {
		t.Fatalf("empty v2 history revived legacy entries: %+v, %v", loaded.Entries, err)
	}
}

func TestRecentProjectsLeaveInstalledPackageUnchanged(t *testing.T) {
	if !installedpackagetest.Run(t) {
		return
	}
	prefs, err := store.Open()
	if err != nil {
		t.Fatal(err)
	}
	installedpackagetest.Outside(t, prefs.Path(recentFile))
	installedpackagetest.Outside(t, prefs.Path(recentLockFile))
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	result, _, err := reduceStoredRecent(ctx, prefs, core.NewClient(), core.RecordRecent(t.TempDir(), time.Unix(1, 0)), true)
	if err != nil || len(result.Entries) != 1 {
		t.Fatalf("write recent history: %+v, %v", result.Entries, err)
	}
	if _, err := os.Stat(prefs.Path(recentLockFile)); err != nil {
		t.Fatal(err)
	}
}
