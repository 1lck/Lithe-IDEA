package workbench

import (
	"context"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/remoteplaceholder"
	"github.com/1lck/Lithe-IDEA/desktop/internal/toolchain"
)

// remoteHostDevcontainers stands in for this computer's Dev Container CLI: an up records what it
// was asked, prints lines and ends with result or fail, or with block set prints lines and runs
// until it is stopped. Listing a folder's configurations is the real Core's.
type remoteHostDevcontainers struct {
	requests []core.DevcontainerUpRequest
	lines    []string
	result   core.DevcontainerUp
	fail     error
	block    bool
	// ended counts the ups that returned.
	ended int
}

func (k *remoteHostKernel) RemoteDevcontainerUp(ctx context.Context, request core.DevcontainerUpRequest, output func(core.DevcontainerOutput)) (core.DevcontainerUp, error) {
	k.mu.Lock()
	d := &k.devcontainers
	d.requests = append(d.requests, request)
	lines, result, fail, block := slices.Clone(d.lines), d.result, d.fail, d.block
	k.mu.Unlock()
	defer k.set(func(k *remoteHostKernel) { k.devcontainers.ended++ })
	for _, line := range lines {
		output(core.DevcontainerOutput{Text: line})
	}
	if block {
		timer := time.NewTimer(10 * time.Second)
		defer timer.Stop()
		select {
		case <-ctx.Done():
		case <-timer.C:
		}
		return core.DevcontainerUp{}, &core.Error{Command: "remote.devcontainerUp", Code: core.CodeCancelled, Message: "cancelled"}
	}
	return result, fail
}

// remoteTestConfig is the folder's first devcontainer.json, which names its configuration.
const remoteTestConfig = ".devcontainer/devcontainer.json"

// remoteDevcontainerFolder is a new folder of this computer with two devcontainer.json files: the
// one the specification looks for first, named Go, and one in a folder below .devcontainer.
func remoteDevcontainerFolder(t *testing.T) string {
	t.Helper()
	folder := filepath.Join(t.TempDir(), "service")
	files := map[string]string{
		remoteTestConfig:                       `{"name": "Go", "image": "golang:1.26"}`,
		".devcontainer/node/devcontainer.json": `{"image": "node:22"}`,
	}
	for name, text := range files {
		path := filepath.Join(folder, filepath.FromSlash(name))
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(text), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return folder
}

// remoteDevcontainerHarness is remoteContainerHarness whose CLI starts remoteTestContainer as app,
// with the Dev Container page open on folder, read.
func remoteDevcontainerHarness(t *testing.T, folder string, trusting bool) (*harness, *remoteHostKernel, *treeRecordingLog) {
	t.Helper()
	h, k, logger := remoteContainerHarness(t)
	h.app.trustEveryWorkspace = !trusting
	k.set(func(k *remoteHostKernel) {
		k.devcontainers.result = core.DevcontainerUp{Container: &core.Devcontainer{
			Engine: core.ContainerEngineDocker, Container: remoteTestContainer, ContainerID: strings.Repeat("a", 64),
			User: "app", WorkspaceFolder: remoteTestFolder,
		}}
	})
	lang := h.app.language()
	h.clickFront(i18n.Shared(lang, "desktop.remote.devcontainer.open"))
	h.settle()
	if h.app.remote.devcontainer == nil || !h.shows(i18n.Shared(lang, "desktop.remote.devcontainer.title")) {
		t.Fatal("the toolbar does not open the Dev Container page")
	}
	// The controlled CLI is usable; this UI test never probes a developer's daemon.
	d := h.app.remote.devcontainer
	d.runtimeID = "test-default"
	d.runtimes.Runtimes = []core.ContainerRuntime{{ID: d.runtimeID, ContainerRuntimeTarget: core.ContainerRuntimeTarget{Engine: core.ContainerEngineDocker}, Available: true}}
	h.driver.QueueOpenDirectory(folder, nil)
	h.clickFront(i18n.Shared(lang, "desktop.remote.devcontainer.choose"))
	awaitRemoteDevcontainerRead(t, h)
	return h, k, logger
}

// pressFront clicks the front-most control named label and paints the next frame, without
// waiting for background work, such as an up that runs until it is stopped.
func (h *harness) pressFront(label string) {
	h.t.Helper()
	point := center(h.frontLabeled(label))
	if err := h.driver.Click(point.X, point.Y); err != nil {
		h.t.Fatal(err)
	}
	if err := h.driver.Pump(); err != nil {
		h.t.Fatal(err)
	}
}

// awaitRemoteDevcontainerRead waits for the page's folder to be read.
func awaitRemoteDevcontainerRead(t *testing.T, h *harness) {
	t.Helper()
	awaitStateWithin(t, h, 10*time.Second, "the folder's configurations", func() bool {
		d := h.app.remote.devcontainer
		return d != nil && !d.reading && (d.read != "" || d.err != "")
	})
	h.settle()
}

// awaitRemoteDevcontainerWorkspace waits for the workspace opened in the container.
func awaitRemoteDevcontainerWorkspace(t *testing.T, h *harness) *project {
	t.Helper()
	awaitStateWithin(t, h, 10*time.Second, "the container's workspace", func() bool {
		p := h.app.project
		return p != nil && p.remote != nil && !p.remote.beating && p.tree.root != nil && p.tree.root.listed && !p.tree.reading
	})
	h.settle()
	return h.app.project
}

// Choosing a folder lists its devcontainer.json files, the specification's first chosen, and Build
// runs the CLI's up for it, allowed to run the folder's code, under the engine chosen. The window
// then enters the container the CLI started as its remoteUser and opens its workspaceFolder, the
// container's way: by engine and name, its trust asked of the host. Neither the folder, the
// configuration, the container nor its user is logged.
func TestRemoteDevcontainerBuildsAndOpensTheWorkspaceFolder(t *testing.T) {
	folder := remoteDevcontainerFolder(t)
	h, k, logger := remoteDevcontainerHarness(t, folder, false)
	lang := h.app.language()
	r := &h.app.remote
	d := r.devcontainer
	paths := make([]string, len(d.configs))
	for i, config := range d.configs {
		paths[i] = config.Path
	}
	if d.read != folder || !slices.Equal(paths, []string{remoteTestConfig, ".devcontainer/node/devcontainer.json"}) || d.config != remoteTestConfig {
		t.Fatalf("read %d configurations, chose %q; want both, the specification's first chosen", len(paths), d.config)
	}
	named := i18n.SharedFormat(lang, "desktop.remote.devcontainer.configNamed", map[string]string{"name": "Go", "path": remoteTestConfig})
	if !h.shows(named) || !h.shows(i18n.Shared(lang, "desktop.remote.devcontainer.build")) ||
		h.shows(i18n.Shared(lang, "desktop.remote.devcontainer.trustAndBuild")) {
		t.Fatal("the page does not show the named configuration and Build")
	}

	h.clickFront(i18n.Shared(lang, "desktop.remote.devcontainer.build"))
	p := awaitRemoteDevcontainerWorkspace(t, h)
	want := core.DevcontainerUpRequest{Folder: folder, Config: remoteTestConfig, Engine: core.ContainerEngineDocker, ProjectCodeAllowed: true, Runtime: &core.ContainerRuntimeTarget{Engine: core.ContainerEngineDocker}}
	if got := k.devcontainers.requests; len(got) != 1 || !reflect.DeepEqual(got[0], want) {
		t.Fatalf("asked for %d ups; want one for the folder's first configuration under Docker", len(got))
	}
	connection := core.ContainerConnection{Engine: core.ContainerEngineDocker, Container: remoteTestContainer, User: "app"}
	if got := k.containers.requests; len(got) != 1 || got[0] != connection {
		t.Fatalf("asked for %d container connections; want the container started, as its remoteUser", len(got))
	}
	identity := "docker:app@" + remoteTestContainer
	anchor, _ := h.app.remoteAnchor()
	if want := remoteplaceholder.Root(anchor, identity, remoteTestFolder); p.root != want || p.remote.connectionID != identity {
		t.Fatal("the workspace folder is not opened in the container")
	}
	if r.devcontainer != nil || r.containers.selected == nil || r.containers.selected.key() != remoteTestContainerKey ||
		r.containers.selected.Image != remoteTestImage {
		t.Fatal("the window does not show the started container's page as listed")
	}
	actions := []string{"remote.connections.open", "remote.connection.new", "remote.connection.save", "remote.connections.open",
		"remote.devcontainer.open", "remote.devcontainer.choose", "remote.devcontainer.build", "remote.connect"}
	if got := remoteActions(logger); !slices.Equal(got, actions) {
		t.Fatalf("performed %q, want %q", got, actions)
	}
	if event := loggedAny(t, logger, folder, "service", "Go", remoteTestConfig, remoteTestContainer, "app@", remoteTestHome); event != "" {
		t.Fatal("logged the folder, its configuration, the container or its user")
	}
}

// A folder that is not trusted shows why building trusts it, and Trust and Build saves the folder
// as trusted, the same decision as opening it as a project, before the CLI runs its code.
func TestRemoteDevcontainerTrustsTheFolderBeforeBuilding(t *testing.T) {
	folder := remoteDevcontainerFolder(t)
	h, k, logger := remoteDevcontainerHarness(t, folder, true)
	lang := h.app.language()
	d := h.app.remote.devcontainer
	trustAndBuild := i18n.Shared(lang, "desktop.remote.devcontainer.trustAndBuild")
	if d.trusted || d.trust.Root == "" || !h.showsWrapped(i18n.Shared(lang, "desktop.remote.devcontainer.untrusted")) || !h.shows(trustAndBuild) {
		t.Fatal("the page does not say the folder is not trusted")
	}
	h.clickFront(trustAndBuild)
	awaitRemoteDevcontainerWorkspace(t, h)
	if got := k.count(func(k *remoteHostKernel) int { return len(k.devcontainers.requests) }); got != 1 {
		t.Fatalf("asked for %d ups after trusting, want 1", got)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	trust, err := toolchain.ReadWorkspaceTrust(ctx, k, h.app.globalToolchainRoot(), folder)
	if err != nil {
		t.Fatal(err)
	}
	if trust.State != core.WorkspaceTrusted {
		t.Fatalf("the folder's trust is %q, want trusted", trust.State)
	}
	actions := remoteActions(logger)
	if at := slices.Index(actions, "remote.devcontainer.build"); at < 0 || !loggedAction(logger, "workspace.trust.grant") {
		t.Fatalf("performed %q: the folder was not trusted before building", actions)
	}
}

// loggedAction reports whether action was performed.
func loggedAction(logger *treeRecordingLog, action string) bool {
	logger.mu.Lock()
	defer logger.mu.Unlock()
	return slices.ContainsFunc(logger.events, func(event core.LogEvent) bool {
		got, _ := event.Fields["action"].(string)
		return event.Event == "app.action.performed" && got == action
	})
}

// A failed up explains itself on the page: a missing CLI says how to install it, a failure the CLI
// reported shows its words, which are not logged, and Core refusing an untrusted folder says
// nothing was built. Each failure is logged once by its code alone, and nothing is entered.
func TestRemoteDevcontainerFailuresAreExplained(t *testing.T) {
	folder := remoteDevcontainerFolder(t)
	h, k, logger := remoteDevcontainerHarness(t, folder, false)
	lang := h.app.language()
	d := h.app.remote.devcontainer
	build := i18n.Shared(lang, "desktop.remote.devcontainer.build")
	diagnostics := "Error: Command failed: docker build -f Dockerfile.private-dev"
	for i, failure := range []struct {
		name   string
		result core.DevcontainerUp
		fail   error
		text   string
	}{
		{"missing", core.DevcontainerUp{}, &core.Error{Command: "remote.devcontainerUp", Code: core.CodeRuntimeMissing, Message: "missing"}, "desktop.remote.devcontainer.missing"},
		{"reported", core.DevcontainerUp{Diagnostics: diagnostics}, nil, "desktop.remote.devcontainer.failed"},
		{"untrusted", core.DevcontainerUp{}, &core.Error{Command: "remote.devcontainerUp", Code: core.CodeDevcontainerUntrustedFolder, Message: "untrusted"}, "desktop.remote.devcontainer.untrustedRefused"},
	} {
		k.set(func(k *remoteHostKernel) { k.devcontainers.result, k.devcontainers.fail = failure.result, failure.fail })
		d.trusted = true
		h.redraw()
		h.clickFront(build)
		awaitStateWithin(t, h, 10*time.Second, failure.name, func() bool { return d.build == nil && d.err != "" })
		h.settle()
		if text := i18n.Shared(lang, failure.text); d.err != text || !h.showsWrapped(text) {
			t.Fatalf("%s: the page does not explain the failure", failure.name)
		}
		if got := countFailures(logger, "remote_devcontainer_up"); got != i+1 {
			t.Fatalf("%s: %d failures logged, want %d", failure.name, got, i+1)
		}
	}
	if d.trusted {
		t.Fatal("Core refusing an untrusted folder leaves it trusted on the page")
	}
	if got := k.count(func(k *remoteHostKernel) int { return len(k.containers.requests) }); got != 0 {
		t.Fatalf("asked for %d container connections after failed ups", got)
	}
	if event := loggedAny(t, logger, diagnostics, "Dockerfile.private-dev"); event != "" {
		t.Fatal("logged the CLI's words")
	}
}

// Stop stops the CLI while its log keeps what it printed, the up's late result is dropped, the
// list's other entries wait while it builds, and Cancel leaves the page.
func TestRemoteDevcontainerStopKeepsTheLog(t *testing.T) {
	folder := remoteDevcontainerFolder(t)
	h, k, logger := remoteDevcontainerHarness(t, folder, false)
	lang := h.app.language()
	r := &h.app.remote
	d := r.devcontainer
	lines := []string{"[2 ms] Start: Run: docker buildx build", "#5 [1/3] FROM golang:1.26"}
	k.set(func(k *remoteHostKernel) { k.devcontainers.lines, k.devcontainers.block = lines, true })
	// The up runs until it is stopped, so the test paints frames without waiting for it.
	h.pressFront(i18n.Shared(lang, "desktop.remote.devcontainer.build"))
	awaitStateWithin(t, h, 10*time.Second, "the CLI's log", func() bool { return slices.Equal(d.lines, lines) && h.shows(lines[1]) })
	if d.build == nil || !h.shows(i18n.Shared(lang, "desktop.remote.devcontainer.building")) || !h.shows(i18n.Shared(lang, "desktop.remote.stop")) {
		t.Fatal("the page does not show the CLI's log with Stop while it builds")
	}

	// The list's other entries wait for the build.
	h.pressFront(remoteTestContainer)
	if r.devcontainer != d || r.containers.selected != nil {
		t.Fatal("choosing a listed container left the page while it builds")
	}

	h.pressFront(i18n.Shared(lang, "desktop.remote.stop"))
	h.settle()
	if got := k.count(func(k *remoteHostKernel) int { return k.devcontainers.ended }); got != 1 {
		t.Fatalf("%d ups ended after Stop, want 1", got)
	}
	if d.build != nil || !d.stopped || d.err != "" || !slices.Equal(d.lines, lines) || r.devcontainer != d {
		t.Fatal("stopping does not keep the page with its log")
	}
	if !h.showsWrapped(i18n.Shared(lang, "desktop.remote.devcontainer.stopped")) || !h.shows(lines[1]) {
		t.Fatal("the page does not say the build was stopped")
	}
	if countFailures(logger, "remote_devcontainer_up") != 0 || k.count(func(k *remoteHostKernel) int { return len(k.containers.requests) }) != 0 {
		t.Fatal("the stopped up's result was applied")
	}

	h.clickFront(i18n.Shared(lang, "desktop.remote.cancel"))
	h.settle()
	if r.devcontainer != nil {
		t.Fatal("Cancel does not leave the page")
	}
	if event := loggedAny(t, logger, lines[0], lines[1]); event != "" {
		t.Fatal("logged the CLI's log")
	}
}

// A folder typed instead of chosen is read on Return: Core refuses a relative path and a missing
// folder, and a folder without devcontainer.json cannot be built.
func TestRemoteDevcontainerFolderErrors(t *testing.T) {
	h, _, _ := remoteContainerHarness(t)
	lang := h.app.language()
	h.app.openRemoteDevcontainer()
	h.settle()
	d := h.app.remote.devcontainer
	empty := t.TempDir()
	for _, typed := range []struct {
		folder, text string
	}{
		{"relative/service", "desktop.remote.devcontainer.folderRelative"},
		{filepath.Join(empty, "gone"), "desktop.remote.devcontainer.folderMissing"},
		{empty, ""},
	} {
		d.folder.SetText(typed.folder)
		h.app.readRemoteDevcontainer()
		awaitRemoteDevcontainerRead(t, h)
		if typed.text == "" {
			continue
		}
		if text := i18n.Shared(lang, typed.text); d.err != text || d.read != "" || !h.showsWrapped(text) {
			t.Fatalf("%s: the page does not explain the folder", typed.text)
		}
	}
	if d.read != empty || len(d.configs) != 0 || d.buildable() || !h.showsWrapped(i18n.Shared(lang, "desktop.remote.devcontainer.createMissing")) {
		t.Fatal("a folder without devcontainer.json does not say so, or may be built")
	}
}
