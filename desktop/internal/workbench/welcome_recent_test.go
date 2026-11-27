package workbench

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/filelock"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/installedpackagetest"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

func (h *harness) seedRecent(entries []core.RecentProject) {
	h.t.Helper()
	h.settle()
	h.await("prior recent refresh", func() bool { return !h.app.recentWrites.refreshing })
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
	intent := core.SetPinnedRecent(project, !second.app.recent[0].Pinned)
	first.pinWelcomeProject(project)
	// Model an intent collected before the other window published its pin.
	second.app.changeRecent(intent, nil)
	second.settle()
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

func TestWelcomeActivatingBeforePinCommitStillReceivesThePin(t *testing.T) {
	first := newHarness(t, &testKernel{Client: core.NewClient()})
	project := t.TempDir()
	first.seedRecent([]core.RecentProject{{Path: project}})
	second := newHarnessWithOptions(t, Options{
		Kernel: &testKernel{Client: core.NewClient()}, Store: store.At(first.store.Dir()),
	})
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	release, err := filelock.Acquire(ctx, first.store.Path(recentLockFile))
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		if release != nil {
			if err := release(); err != nil {
				t.Error(err)
			}
		}
	}()
	first.app.changeRecent(core.SetPinnedRecent(project, true), nil)
	second.config.OnActivate()
	second.settle()
	err = release()
	release = nil
	if err != nil {
		t.Fatal(err)
	}
	first.settle()
	if !first.app.recent[0].Pinned {
		t.Fatal("pin did not commit")
	}
	second.await("the committed pin in the already active window", func() bool {
		return len(second.app.recent) == 1 && second.app.recent[0].Pinned
	})
}

func TestWelcomeDoesNotOpenMissingRemoteRecent(t *testing.T) {
	h, k, _, logger := remoteWorkspaceHarness(t)
	h.openRemoteTestProject(t)
	h.app.closeProject()
	h.await("welcome screen", func() bool { return h.app.project == nil })
	h.settle()
	before := h.app.recent[0]
	k.set(func(k *remoteHostKernel) {
		k.git.trustErr = &core.Error{Code: core.CodeWorkspaceNotFound, Message: remoteTestFolder}
		k.missing = true
	})
	h.app.openRecent(before.Path)
	h.await("reopen result", func() bool {
		b := h.app.remote.browser
		return h.app.project != nil || (b != nil && b.err != "")
	})
	if h.app.project != nil {
		t.Fatal("missing remote folder opened as a project")
	}
	if got := h.app.recent[0]; got.LastOpenedAt != before.LastOpenedAt {
		t.Fatal("missing remote folder was recorded as opened")
	}
	if event := loggedAny(t, logger, remoteTestFolder); event != "" {
		t.Fatalf("remote folder leaked in %s", event)
	}
}

func TestWelcomeReceivesRecentFileReplacementWithoutActivation(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	project := t.TempDir()
	h.seedRecent([]core.RecentProject{{Path: project}})
	state := h.app.settingsSubscription.editorPreferences
	h.await("native preference watcher registration", func() bool {
		state.Lock()
		defer state.Unlock()
		return state.watchReady
	})
	// A separate store writes without the in-process publication.
	if err := store.At(h.store.Dir()).Save(recentFile, []core.RecentProject{{Path: project, Pinned: true}}); err != nil {
		t.Fatal(err)
	}
	h.await("the observed replacement", func() bool {
		return len(h.app.recent) == 1 && h.app.recent[0].Pinned
	})
}

func TestWelcomeRetriesRecentLocalContainerWithTheSameTarget(t *testing.T) {
	h, k, _, _ := remoteWorkspaceHarness(t)
	h.app.closeRemote()
	container := &core.ContainerConnection{Engine: core.ContainerEngineDocker, Container: remoteTestContainer, User: "app"}
	remote := &core.RecentRemoteProject{
		ConnectionID: container.Identity(), Name: remoteTestContainer, Folder: remoteTestFolder, Container: container,
	}
	k.set(func(k *remoteHostKernel) { k.containers.refuse = errors.New("container is stopped") })
	h.app.openRecentRemote(remote)
	h.await("connection failure", func() bool { return h.app.remote.steps != nil && h.app.remote.steps.failed })
	before := k.count(func(k *remoteHostKernel) int { return k.connects })
	k.set(func(k *remoteHostKernel) { k.containers.refuse = nil })
	h.clickFront(i18n.Shared(h.app.language(), "desktop.remote.steps.retry"))
	h.settle()
	if after := k.count(func(k *remoteHostKernel) int { return k.connects }); after != before+1 {
		t.Fatalf("retry made %d connection attempts, expected one", after-before)
	}
	h.await("the original container directory", func() bool {
		p := h.app.project
		return p != nil && p.remote != nil && p.remote.binding.RemoteRoot() == remote.Folder
	})
	if got := h.app.project.remote.host.container; got == nil || *got != *container {
		t.Fatalf("retried container = %+v, want %+v", got, container)
	}
}

func TestWelcomeTagFilterSurvivesCaseVariantReordering(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	base := t.TempDir()
	alpha := welcomeRecentDir(t, base, "alpha")
	beta := welcomeRecentDir(t, base, "beta")
	other := welcomeRecentDir(t, base, "other")
	h.seedRecent([]core.RecentProject{
		{Path: alpha, LastOpenedAt: 3, Tags: []string{"Work"}},
		{Path: beta, LastOpenedAt: 2, Tags: []string{"work"}},
		{Path: other, LastOpenedAt: 1},
	})
	h.resizeWelcome()
	h.clickNamed(h.shared("desktop.welcome.filterTags"))
	h.clickNamed("Work")
	h.pinWelcomeProject(beta)
	h.await("the newly pinned project", func() bool { return h.app.recent[0].Pinned })
	if !h.shows("alpha") || !h.shows("beta") || h.shows("other") {
		t.Fatal("pinning a case variant cleared the selected filter")
	}
}

func TestRecentProjectsCanStartNewHistoryAfterDamagedLegacyJSON(t *testing.T) {
	prefs := store.At(t.TempDir())
	old := []byte(`[{"path":`)
	if err := os.WriteFile(prefs.Path(legacyRecentFile), old, 0o600); err != nil {
		t.Fatal(err)
	}
	project := t.TempDir()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	result, _, err := reduceStoredRecent(ctx, prefs, core.NewClient(), core.RecordRecent(project, time.Unix(1, 0)), true)
	if err != nil || len(result.Entries) != 1 || result.Entries[0].Path != project {
		t.Fatalf("save new recent history: %+v, %v", result.Entries, err)
	}
	if data, err := os.ReadFile(prefs.Path(legacyRecentFile)); err != nil || string(data) != string(old) {
		t.Fatalf("legacy history changed: %q, %v", data, err)
	}
}
