package workbench

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
)

// trustHarness is a window that asks about trust, as a user's does: the harness otherwise
// opens every folder trusted. Its trust decisions go to the toolchain catalog in the window's
// own temporary preference directory.
func trustHarness(t *testing.T) *harness {
	t.Helper()
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.app.trustEveryWorkspace = false
	return h
}

// trustFolder is a new folder named name in a new parent folder.
func trustFolder(t *testing.T, name string) string {
	t.Helper()
	dir := filepath.Join(t.TempDir(), name)
	if err := os.Mkdir(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	return dir
}

// openAsking opens dir and waits for the question about trusting it.
func openAsking(t *testing.T, h *harness, dir string) *pluginPrompt {
	t.Helper()
	h.app.openProjectHere(dir)
	awaitStateWithin(t, h, 10*time.Second, "the trust question", func() bool { return len(h.app.prompts.queue) == 1 })
	h.settle()
	return h.app.prompts.queue[0]
}

// awaitOpened waits until dir is the open project.
func awaitOpened(t *testing.T, h *harness, dir string) *project {
	t.Helper()
	awaitStateWithin(t, h, 10*time.Second, "the project to open", func() bool {
		return h.app.project != nil && h.app.project.root == dir
	})
	return h.app.project
}

// reopen closes the open project and opens dir again.
func reopen(t *testing.T, h *harness, dir string) *project {
	t.Helper()
	h.app.closeProject()
	awaitStateWithin(t, h, 10*time.Second, "the project to close", func() bool { return h.app.project == nil })
	h.app.openProjectHere(dir)
	return awaitOpened(t, h, dir)
}

func TestTrustingAFolderOpensItAndIsRemembered(t *testing.T) {
	h := trustHarness(t)
	dir := trustFolder(t, "demo")
	language := h.app.language()

	prompt := openAsking(t, h, dir)
	if h.app.project != nil {
		t.Fatal("the folder opened before the user answered")
	}
	title := i18n.SharedFormat(language, "desktop.trust.openTitle", map[string]string{"project": "demo"})
	home, _ := os.UserHomeDir()
	location := i18n.SharedFormat(language, "desktop.trust.location", map[string]string{"folder": trustFolderLabel(filepath.Dir(dir), home)})
	if prompt.title != title || !h.shows(i18n.Shared(language, "desktop.trust.previewSafeMode")) || !h.shows(location) {
		t.Fatalf("the question is %q with the check %q, want %q offering the parent folder", prompt.title, prompt.check, title)
	}

	h.clickShared("desktop.trust.trustProject")
	p := awaitOpened(t, h, dir)
	if p.safeMode() {
		t.Fatal("a trusted project opened in safe mode")
	}
	if p = reopen(t, h, dir); p.safeMode() || len(h.app.prompts.queue) != 0 {
		t.Fatalf("reopening asked again (%d questions) or opened in safe mode", len(h.app.prompts.queue))
	}
	if _, err := os.Stat(filepath.Join(dir, ".lithe")); !os.IsNotExist(err) {
		t.Fatalf("trusting wrote into the project: %v", err)
	}
}

func TestTrustingTheParentFolderTrustsItsOtherProjects(t *testing.T) {
	h := trustHarness(t)
	dir := trustFolder(t, "first")
	sibling := filepath.Join(filepath.Dir(dir), "second")
	if err := os.Mkdir(sibling, 0o755); err != nil {
		t.Fatal(err)
	}

	openAsking(t, h, dir)
	h.clickLabeled(h.app.prompts.queue[0].check)
	if !h.app.prompts.queue[0].checked {
		t.Fatal("clicking the parent folder's checkbox did not check it")
	}
	h.clickShared("desktop.trust.trustProject")
	awaitOpened(t, h, dir)

	if p := reopen(t, h, sibling); p.safeMode() || len(h.app.prompts.queue) != 0 {
		t.Fatal("a project in the trusted folder was not trusted")
	}
}

func TestDontOpenLeavesTheWindowAsItWas(t *testing.T) {
	h := trustHarness(t)
	dir := trustFolder(t, "demo")

	openAsking(t, h, dir)
	h.clickShared("desktop.trust.dontOpen")
	h.settle()
	if h.app.project != nil || len(h.app.prompts.queue) != 0 {
		t.Fatal("Don't Open opened the folder or left the question")
	}
	// Nothing was decided, so the next open asks again.
	openAsking(t, h, dir)
}

func TestSafeModeKeepsProjectCodeFromRunningUntilTrusted(t *testing.T) {
	h := trustHarness(t)
	dir := trustFolder(t, "demo")
	source := filepath.Join(dir, "Main.java")
	if err := os.WriteFile(source, []byte("class Main {}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	language := h.app.language()

	openAsking(t, h, dir)
	h.clickShared("desktop.trust.previewSafeMode")
	p := awaitOpened(t, h, dir)
	if !p.safeMode() {
		t.Fatal("Preview in Safe Mode opened the project trusted")
	}
	// The choice is remembered: the folder opens in safe mode without asking.
	if p = reopen(t, h, dir); !p.safeMode() || len(h.app.prompts.queue) != 0 {
		t.Fatal("reopening a folder previewed in safe mode asked again or trusted it")
	}

	// A model is not loaded: loading one runs the build tool.
	setDetected(p, []buildInstance{{BuildInstance: core.BuildInstance{ID: "fixture:."}}})
	h.app.loadBuildModel(p, 0)
	if instance := p.build.instances[0]; instance.modelLoading || !instance.modelUntrusted || instance.modelError != i18n.Shared(language, "desktop.trust.modelSafeMode") {
		t.Fatalf("in safe mode the model load = loading %v, untrusted %v, %q", instance.modelLoading, instance.modelUntrusted, instance.modelError)
	}

	// A run asks first; staying in safe mode runs nothing.
	ran := 0
	h.app.startRun(p, "app", func(*App, *project) { ran++ })
	awaitStateWithin(t, h, 10*time.Second, "the question before the run", func() bool { return len(h.app.prompts.queue) == 1 })
	h.settle()
	h.clickShared("desktop.trust.stayInSafeMode")
	h.settle()
	if ran != 0 || !p.safeMode() {
		t.Fatal("staying in safe mode ran the program or left safe mode")
	}

	// The notice above the editor offers to trust the project; trusting it leaves safe mode.
	h.app.openFile(p, source)
	h.settle()
	if !h.shows(i18n.Shared(language, "desktop.trust.banner")) {
		t.Fatal("the editor does not say the project is in safe mode")
	}
	h.clickShared("desktop.trust.bannerLink")
	awaitStateWithin(t, h, 10*time.Second, "the trust question", func() bool { return len(h.app.prompts.queue) == 1 })
	h.settle()
	h.clickShared("desktop.trust.trustProject")
	awaitStateWithin(t, h, 10*time.Second, "the project to leave safe mode", func() bool { return !p.safeMode() })
	h.settle()
	if h.shows(i18n.Shared(language, "desktop.trust.banner")) {
		t.Fatal("the safe mode notice stayed after trusting the project")
	}
	if p.build.instances[0].modelUntrusted {
		t.Fatal("trusting the project left the model unloaded for safe mode")
	}
	h.app.startRun(p, "app", func(*App, *project) { ran++ })
	if ran != 1 {
		t.Fatalf("a run in the trusted project ran %d times, want at once", ran)
	}
}

// In safe mode no Git process runs, since the repository's configuration can name programs Git
// runs: the Commit window says so in place of the changes, the repository's metadata is not
// watched, and trusting the project from the window loads the changes (#2208).
func TestSafeModeRunsNoGitUntilTrusted(t *testing.T) {
	dir := newTestRepository(t)
	h := newHarness(t, &gitKernel{Client: core.NewClient()})
	h.app.trustEveryWorkspace = false
	language := h.app.language()

	openAsking(t, h, dir)
	h.clickShared("desktop.trust.previewSafeMode")
	p := awaitOpened(t, h, dir)
	h.click(center(h.button(itemCommit)))
	h.settle()
	if !p.git.safeMode || p.git.isRepository() || p.git.err != nil {
		t.Fatalf("safe mode read the repository: %+v", p.git)
	}
	if !h.showsWrapped(i18n.Shared(language, "desktop.trust.gitSafeMode")) || h.shows("changed.txt") {
		t.Fatal("the Commit window does not say safe mode runs no Git, or lists the changes")
	}
	if p.observe.metadata != nil || p.observe.watches != nil {
		t.Fatal("safe mode watches the repository's metadata")
	}

	h.clickShared("desktop.trust.bannerLink")
	awaitStateWithin(t, h, 10*time.Second, "the trust question", func() bool { return len(h.app.prompts.queue) == 1 })
	h.settle()
	h.clickShared("desktop.trust.trustProject")
	awaitStateWithin(t, h, 10*time.Second, "the changes to load", func() bool { return p.git.isRepository() })
	h.settle()
	if p.git.safeMode || !h.shows("changed.txt") || h.showsWrapped(i18n.Shared(language, "desktop.trust.gitSafeMode")) {
		t.Fatal("trusting the project did not list the changes")
	}
	awaitStateWithin(t, h, 10*time.Second, "the metadata watch", func() bool { return p.observe.metadata != nil })

	// Withdrawing the trust stops Git again: the status and the watch of the metadata.
	h.app.applyProjectTrust(p, false)
	h.settle()
	if !p.git.safeMode || p.observe.metadata != nil || p.observe.watches != nil {
		t.Fatalf("withdrawn trust kept Git running: git %+v, watching %v", p.git, p.observe.watches)
	}
	if !h.showsWrapped(i18n.Shared(language, "desktop.trust.gitSafeMode")) || h.shows("changed.txt") {
		t.Fatal("the Commit window still lists the changes of an untrusted project")
	}
}

// In safe mode Core refuses to start a language server that does not declare it runs no project
// code; the host keeps the refusal as safe mode, not as a failure, and trusting the project
// starts the server again (#2208).
func TestSafeModeStartsNoLanguageServerUntilTrusted(t *testing.T) {
	kernel := &testKernel{Client: core.NewClient()}
	h := newHarness(t, kernel)
	h.app.plugins = settingsFixturePlugins(t, kernel)
	h.open(t.TempDir())
	p := h.app.project
	p.trust.codeAllowed.Store(false)

	failure := func() *failedPluginServer {
		h.app.pluginServerMu.Lock()
		defer h.app.pluginServerMu.Unlock()
		if h.app.pluginServerStarting["fixture"] {
			return nil
		}
		return h.app.pluginServerFailed["fixture"]
	}
	h.app.startPluginServer("fixture")
	awaitStateWithin(t, h, 10*time.Second, "the refused start", func() bool { return failure() != nil })
	refused := failure()
	if !refused.untrusted || refused.message != i18n.Shared(h.app.language(), "desktop.trust.lspSafeMode") {
		t.Fatalf("refused start = %+v, want safe mode", refused)
	}
	if len(h.app.notifications.list) != 0 {
		t.Fatalf("safe mode notified %+v", h.app.notifications.list)
	}

	// The fixture's command may not run here; what matters is that Core no longer refuses it.
	h.app.applyProjectTrust(p, true)
	awaitStateWithin(t, h, 10*time.Second, "the start after trust", func() bool {
		h.app.pluginServerMu.Lock()
		defer h.app.pluginServerMu.Unlock()
		return !h.app.pluginServerStarting["fixture"] && (h.app.pluginServerFailed["fixture"] != nil || h.app.pluginServerLanguages["fixture"] != "")
	})
	if failed := failure(); failed != nil && failed.untrusted {
		t.Fatalf("the start after trust = %+v, still safe mode", failed)
	}
	h.app.stopAllPluginServers()
}

func TestTrustFolderLabelShortensHomeAndLongPaths(t *testing.T) {
	home := filepath.Join(string(filepath.Separator)+"Users", "ann")
	// Core returns a slash-separated location even on Windows.
	folder := filepath.ToSlash(filepath.Join(home, "IdeaProjects"))
	if got, want := trustFolderLabel(folder, home), "~"+string(filepath.Separator)+"IdeaProjects"; got != want {
		t.Fatalf("label = %q, want %q", got, want)
	}
	long := filepath.Join(string(filepath.Separator)+"srv", "builds", "a-very-long-folder-name-for-every-checkout", "of-the-team", "projects")
	got := []rune(trustFolderLabel(long, home))
	if len(got) != trustFolderMaxRunes || string(got[:5]) != string([]rune(long)[:5]) || !strings.HasSuffix(string(got), "projects") || !strings.Contains(string(got), "…") {
		t.Fatalf("long label = %q, want %d runes keeping its start and its own name", string(got), trustFolderMaxRunes)
	}
}

func TestTrustEllipsisShowsTheFullLocationAndKeepsCheckbox(t *testing.T) {
	h := trustHarness(t)
	dir := filepath.Join(t.TempDir(), strings.Repeat("long-directory-", 6), "project")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	prompt := openAsking(t, h, dir)
	full := i18n.SharedFormat(h.app.language(), "desktop.trust.location", map[string]string{"folder": filepath.Dir(dir)})
	if prompt.checkFull != full || !strings.Contains(prompt.check, "…") {
		t.Fatalf("the shortened trust label %q lost its full location %q", prompt.check, prompt.checkFull)
	}
	point := center(h.hitLabeled(prompt.check))
	if err := h.driver.Move(point.X, point.Y); err != nil {
		t.Fatal(err)
	}
	if err := h.driver.Advance(time.Second); err != nil {
		t.Fatal(err)
	}
	var tip strings.Builder
	for _, label := range h.tooltips() {
		tip.WriteString(label.Value)
	}
	if got := strings.Join(strings.Fields(tip.String()), ""); got != strings.Join(strings.Fields(full), "") {
		t.Fatalf("trust tooltip %q, want %q", tip.String(), full)
	}
	h.clickLabeled(prompt.check)
	if !prompt.checked {
		t.Fatal("the full-text hint intercepted the checkbox click")
	}
}
