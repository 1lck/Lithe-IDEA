//go:build lithe_remote_e2e && (darwin || windows)

package workbench

import (
	"archive/zip"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/configfile"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/marketplace"
	"github.com/1lck/Lithe-IDEA/desktop/internal/plugininstall"
	"github.com/1lck/Lithe-IDEA/desktop/internal/plugintrust"
	"github.com/1lck/Lithe-IDEA/desktop/internal/remoteplaceholder"
	"github.com/1lck/Lithe-IDEA/desktop/internal/remoteserver"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

// Run with -tags lithe_remote_e2e, a staged server, and
// LITHE_TEST_VARIANT_SSH_HOST set to a disposable Linux x86_64 host. The SSH
// configuration may be supplied by LITHE_TEST_VARIANT_SSH_PROGRAM.
func TestEditorDeploysPackagedLanguageServerToLinuxX64OverSSH(t *testing.T) {
	host := os.Getenv("LITHE_TEST_VARIANT_SSH_HOST")
	if host == "" {
		t.Skip("set LITHE_TEST_VARIANT_SSH_HOST to a disposable Linux x86_64 OpenSSH target")
	}
	const id = "io.github.example.remote-variant-fixture"
	const version = "1.0.0"
	const programPath = "bin/server"
	const repository = "https://github.com/example/remote-variant"
	const indexURL = "https://raw.githubusercontent.com/example/lithe-plugins/HEAD/lithe-plugin-index.json"
	const remoteURL = repository + "/releases/download/1.0.0/linux-x64.zip"
	const runtimeURL = "https://runtimes.example.test/runner-linux-x64.zip"
	const diagnostic = "Packaged language server running on linux/amd64 via managed runtime"
	runtimeArchive, runtimeDigest := writeVariantArchive(t, "runner", []variantArchiveFile{
		{"bin/runner", []byte("#!/bin/sh\nif [ \"$1\" = --version ]; then echo 'Runner 1'; exit 0; fi\nexport LITHE_TEST_MANAGED_RUNNER=1\nexec \"$@\"\n"), 0o755},
	})
	manifest := fmt.Sprintf(`{
	  "schemaVersion": 0, "pluginAPIVersion": 0, "id": %q,
	  "displayName": "Remote Variant Fixture", "version": %q,
	  "requires": {"backend": 0, "languages": 0, "languageServers": 0, "managedRuntimes": 0, "toolDefinitions": 0},
	  "vendor": {"id": "io.github.example", "displayName": "Example", "signatureRequirement": "none"},
	  "permissions": ["backend.launch", "languageServer.launch", "runtimes.install"],
	  "backend": {"launch": {"kind": "packaged", "path": "bin/backend"}},
	  "activationEvents": ["onLanguage:example"],
	  "languages": [{"id": "example", "displayName": "Example", "fileExtensions": ["example"]}],
	  "languageServers": [{"languageID": "example", "remote": "supported",
	    "launch": {"kind": "runtime", "tool": "fixture-runner", "minimumVersion": "1", "entry": %q}}],
	  "requiresTools": ["fixture-runner"],
	  "toolDefinitions": [{
	    "id": "fixture-runner", "displayName": "Fixture runner", "icon": {"host": "plugin"},
	    "executableLayouts": [{"path": "bin/runner"}],
	    "executables": [{"id": "shell", "kind": "command", "command": "fixture-runner"}],
	    "version": {"arguments": ["--version"], "pattern": "Runner (\\d+)"},
	    "commands": ["fixture-runner"],
	    "launch": ["${executable}", "${entry}", "${arguments}"]
	  }],
	  "managedRuntimes": {
	    "resolve": {"function": "fixture.resolve"},
	    "dependencies": [{"id": "runner", "tool": "fixture-runner", "version": "1",
	      "artifacts": [{"os": "linux", "arch": "x86_64", "url": %q, "sha256": %q,
	        "archive": "zip", "stripPrefix": "runner", "executable": "bin/runner"}]}]
	  }
	}`, id, version, programPath, runtimeURL, runtimeDigest)

	linuxProgram := buildLinuxVariantLanguageServer(t)
	localArchive, localDigest := pluginProgramVariantArchive(t, id, manifest, programPath, []byte("#!/bin/sh\nexit 1\n"))
	linuxArchive, linuxDigest := pluginProgramVariantArchive(t, id, manifest, programPath, linuxProgram)
	index := fmt.Sprintf(`{
	  "schemaVersion": 0,
	  "plugins": [{
	    "id": %q, "name": "Remote Variant Fixture", "author": "Example",
	    "repository": %q, "description": "Tests exact remote variants.", "license": "MIT",
	    "versions": [
	      {"version": "2.0.0", "pluginAPIVersion": 0, "releaseDate": "2026-10-01",
	       "requires": {"backend": 0, "languageServers": 0, "languages": 0, "managedRuntimes": 0, "toolDefinitions": 0},
	       "downloads": [{"platforms": ["linux-x64"], "downloadURL": %q, "sha256": %q}]},
	      {"version": %q, "pluginAPIVersion": 0, "releaseDate": "2026-10-01",
	       "requires": {"backend": 0, "languageServers": 0, "languages": 0, "managedRuntimes": 0, "toolDefinitions": 0},
	       "downloads": [
	         {"platforms": [%q], "downloadURL": %q, "sha256": %q},
	         {"platforms": ["linux-x64"], "downloadURL": %q, "sha256": %q}
	       ]}
	    ]
	  }]
	}`, id, repository, repository+"/releases/download/2.0.0/linux-x64.zip", strings.Repeat("5", 64),
		version, marketplace.CurrentPlatform(), repository+"/releases/download/1.0.0/desktop.zip", localDigest, remoteURL, linuxDigest)

	client := core.NewClient()
	connection, connected := connectVariantSSH(t, client, host)
	session := connected.Session.ID
	platform := connected.Host.PluginPlatform()
	if platform == nil || platform.OS != "linux" || platform.Arch != "x86_64" {
		t.Fatalf("target = %+v, want Linux x86_64", connected.Host)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	var directory struct {
		Path string `json:"path"`
	}
	if err := client.RemoteHostRequest(ctx, session, "fs.createRunDirectory", map[string]string{"directoryId": "language-variant"}, &directory); err != nil || !path.IsAbs(directory.Path) {
		t.Fatalf("create remote fixture directory: path=%q, err=%v", directory.Path, err)
	}
	const filename = "source.example"
	if _, saved, err := client.RemoteWriteFile(ctx, session, path.Join(directory.Path, filename), []byte("example\n"), nil); err != nil || !saved {
		t.Fatalf("write remote fixture: saved=%v, err=%v", saved, err)
	}

	settings := t.TempDir()
	writeFixture(t, settings, map[string]string{settingsFile: `{"theme":"dark"}`})
	h := newHarnessWithOptions(t, Options{
		Kernel: &testKernel{Client: client}, PluginKernel: client, PluginRoot: t.TempDir(),
		Store: store.At(settings), Languages: []string{"en"},
	})
	service := h.app.plugins
	if service == nil {
		t.Fatal("the plugin service did not open")
	}
	service.RuntimeDownloader = marketplace.NewArchiveDownloader(&http.Client{
		Transport: pluginArchiveTransport(func(request *http.Request) (*http.Response, error) {
			var data []byte
			switch request.URL.String() {
			case indexURL:
				data = []byte(index)
			case remoteURL:
				data = linuxArchive
			case runtimeURL:
				data = runtimeArchive
			default:
				return nil, fmt.Errorf("unexpected marketplace request to %s", request.URL)
			}
			return &http.Response{
				StatusCode: http.StatusOK, Header: make(http.Header),
				Body: io.NopCloser(bytes.NewReader(data)), ContentLength: int64(len(data)), Request: request,
			}, nil
		}),
	})
	archiveFile := filepath.Join(t.TempDir(), "desktop.zip")
	if err := os.WriteFile(archiveFile, localArchive, 0o600); err != nil {
		t.Fatal(err)
	}
	plan, err := h.app.preparePlugin(ctx, plugininstall.Request{
		ArchivePath: archiveFile, Root: service.Root, Source: plugintrust.Marketplace,
		ArchiveSHA256: localDigest, MarketplaceIndexURL: indexURL, MarketplaceRepository: repository,
		ExpectedID: id, ExpectedVersion: version,
	})
	if err != nil {
		var rejection *core.MarketplaceRejection
		if errors.As(err, &rejection) {
			t.Fatalf("prepare plugin at %q: %v", rejection.Field, err)
		}
		t.Fatalf("prepare plugin: %v", err)
	}
	t.Cleanup(func() {
		if err := service.Installer.Discard(plan); err != nil {
			t.Errorf("discard installation staging: %v", err)
		}
	})
	installed, err := service.Installer.Commit(plan)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := service.Manager.EnableInstalled(id); err != nil {
		t.Fatal(err)
	}
	cancel()
	h.app.reloadPluginLanguages()

	anchor := filepath.Join(t.TempDir(), remoteplaceholder.AnchorName)
	if err := remoteplaceholder.Ensure(anchor); err != nil {
		t.Fatal(err)
	}
	const connectionID = "language-variant-ssh"
	root := remoteplaceholder.Root(anchor, connectionID, directory.Path)
	h.app.openRemoteProject(remoteTarget{
		connectionID: connectionID, name: "Language variant SSH test", host: connection,
		session: *connected.Session, platform: platform, remoteRoot: directory.Path, root: root, trusted: true,
	})
	project := h.app.project
	if project == nil || project.remote == nil {
		t.Fatal("the SSH project did not open")
	}
	file := filepath.Join(root, filename)
	h.app.openFileAt(project, file, 1)
	awaitStateWithin(t, h, time.Minute, diagnostic, func() bool {
		for _, server := range h.app.lspFailedServers() {
			if server.displayID() == id || server.languageID == "example" {
				t.Fatalf("start remote language server: %s; logs: %+v", server.message, server.logs)
			}
		}
		return problemMessagesContain(h.app, diagnostic) && diagnosticsForFile(h.app, file) > 0
	})
	t.Log("The managed Linux x86_64 runtime started the selected language server and the editor received diagnostics")

	verify, cancelVerify := context.WithTimeout(project.ctx, 15*time.Second)
	defer cancelVerify()
	expected, err := client.PlanMarketplaceRemoteDeployment(verify, core.MarketplaceDeploymentRequest{
		Manifest: plan.Manifest, Target: *platform, RequiredPaths: []string{programPath}, ArchiveSHA256: linuxDigest,
	})
	if err != nil {
		t.Fatalf("plan expected deployment: %v", err)
	}
	key := core.RemotePluginDeployment{
		PluginID: id, Version: version, SHA256: expected.SHA256,
	}
	deployment, err := client.LookupRemotePluginDeployment(verify, key)
	if err != nil || !path.IsAbs(deployment) {
		t.Fatalf("lookup same-version deployment by archive checksum: path=%q, err=%v", deployment, err)
	}
	program := path.Join(deployment, programPath)
	metadata, err := client.RemoteStat(verify, session, program)
	if err != nil || metadata.Mode != 0o500 {
		t.Fatalf("remote program mode = %#o, want 0500; err=%v", metadata.Mode, err)
	}
	data, _, err := client.RemoteReadFile(verify, session, program)
	if err != nil || sha256.Sum256(data) != sha256.Sum256(linuxProgram) {
		t.Fatalf("deployed binary differs from the verified Linux variant: bytes=%d, err=%v", len(data), err)
	}
	localProgram, err := os.ReadFile(filepath.Join(installed.Path, programPath))
	if err != nil || string(localProgram) != "#!/bin/sh\nexit 1\n" {
		t.Fatalf("desktop plugin changed: err=%v", err)
	}
	if err := service.Uninstall(verify, id, nil); err != nil {
		t.Fatalf("uninstall the plugin and stop its language server: %v", err)
	}
	cancelVerify()
	h.app.closeProject()
	awaitStateWithin(t, h, 15*time.Second, "the initial workspace to close and release its deployment lease", func() bool {
		return h.app.project == nil && !h.app.closingProject
	})
	_, reconnected := connectVariantSSH(t, client, host)
	binding := core.NewRemoteWorkspace(root, directory.Path, nil)
	binding.Attach(reconnected.Session.ID)
	cleanup, cancelCleanup := context.WithTimeout(binding.CaptureConnection().Context(context.Background()), 15*time.Second)
	defer cancelCleanup()
	if _, err := client.RemoteStat(cleanup, reconnected.Session.ID, program); err != nil {
		t.Fatalf("the published program was missing before the installed-version sweep: %v", err)
	}
	if err := service.SweepRemoteDeployments(cleanup); err != nil {
		t.Fatalf("reconcile the remote deployments against the desktop installations: %v", err)
	}
	if got, err := client.LookupRemotePluginDeployment(cleanup, key); err != nil || got != "" {
		t.Fatalf("the uninstalled plugin's deployment remained after the sweep: path=%q, err=%v", got, err)
	}
}

// Exercises the same settings worker used by the preferences window over SSH.
func TestProjectPluginSettingsUseTheSSHHost(t *testing.T) {
	host := os.Getenv("LITHE_TEST_VARIANT_SSH_HOST")
	if host == "" {
		t.Skip("set LITHE_TEST_VARIANT_SSH_HOST to a disposable Linux OpenSSH target")
	}
	const id = "io.github.example.remote-project-settings-fixture"
	client := core.NewClient()
	connection, connected := connectVariantSSH(t, client, host)
	session := connected.Session.ID
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	directory, err := client.RemoteTempDirectory(ctx, session, "lithe-project-settings-test")
	if err != nil || !path.IsAbs(directory) {
		t.Fatalf("create remote settings fixture: path=%q, err=%v", directory, err)
	}
	defer func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := client.RemoteRemove(ctx, session, directory, true); err != nil {
			t.Errorf("release SSH settings fixture: %v", err)
		}
	}()
	manifest := fmt.Sprintf(`{
	  "schemaVersion":0,"pluginAPIVersion":0,"id":%q,
	  "displayName":"Remote settings fixture","version":"1.0.0",
	  "vendor":{"id":"io.github.example","displayName":"Fixture","signatureRequirement":"none"},
	  "requires":{"languageServers":0,"languages":0,"settings":0},
	  "permissions":["languageServer.launch"],
	  "activationEvents":["onLanguage:settings-fixture"],
	  "languages":[{"id":"settings-fixture","displayName":"Settings fixture","fileExtensions":["settings-fixture"]}],
	  "languageServers":[{"languageID":"settings-fixture","remote":"unsupported","launch":{"kind":"systemCommand","commands":["settings-fixture-lsp"]}}],
	  "settings":[{"id":"flag","type":"boolean","title":"Flag","default":true,"scope":"project","effect":"reload"}]
	}`, id)
	pluginRoot := t.TempDir()
	writeFixture(t, pluginRoot, map[string]string{filepath.Join(id, "1.0.0", "plugin.json"): manifest})
	clientSettings := t.TempDir()
	writeFixture(t, clientSettings, map[string]string{settingsFile: `{"theme":"dark"}`})
	h := newHarnessWithOptions(t, Options{
		Kernel: &testKernel{Client: client}, PluginKernel: client, PluginRoot: pluginRoot,
		Store: store.At(clientSettings), Languages: []string{"en"},
	})
	if _, err := h.app.plugins.Manager.EnableInstalled(id); err != nil {
		t.Fatal(err)
	}
	// Use a writable decoy here to detect accidental client-side writes.
	// Production workspace roots are under a read-only regular-file anchor.
	const connectionID = "project-settings-ssh"
	root := filepath.Join(t.TempDir(), "workspace")
	h.app.openRemoteProject(remoteTarget{
		connectionID: connectionID, name: "Settings SSH fixture", host: connection,
		session: *connected.Session, remoteRoot: directory, root: root, trusted: true,
	})
	project := h.app.project
	if project == nil || project.remote == nil {
		t.Fatal("the SSH project did not open")
	}
	localFile := filepath.Join(root, ".lithe", "plugin-settings.json")
	writeFixture(t, root, map[string]string{filepath.Join(".lithe", "plugin-settings.json"): "local sentinel"})
	settings := pluginSettingsSources{app: h.app}
	editor, err := settings.Load(ctx, id, i18n.English)
	if err != nil {
		t.Fatal(err)
	}
	edits := []core.PluginSettingEdit{{ID: "flag", Value: json.RawMessage("false")}}
	result, err := settings.Save(ctx, editor, "project", edits)
	if err != nil || !result.Committed || result.Readback == nil {
		t.Fatalf("save to SSH host: committed=%v, readback=%v, err=%v", result.Committed, result.Readback != nil, err)
	}
	effective := result.Readback.State.Rows[0].Effective
	if string(effective.Value) != "false" || effective.Source != "project" {
		t.Fatalf("read-back used the wrong source: %+v", effective)
	}
	hostFile := path.Join(directory, ".lithe", "plugin-settings.json")
	content, version, err := client.RemoteReadFile(ctx, session, hostFile)
	var preferences map[string]map[string]json.RawMessage
	if err != nil || json.Unmarshal(content, &preferences) != nil || string(preferences[id]["flag"]) != "false" {
		t.Fatalf("saved preference on the SSH host: %q, %v", content, err)
	}
	reloaded, err := settings.Load(ctx, id, i18n.English)
	if err != nil {
		t.Fatal(err)
	}
	external := bytes.Replace(content, []byte("false"), []byte("true"), 1)
	if _, saved, err := client.RemoteWriteFile(ctx, session, hostFile, external, &version); err != nil || !saved {
		t.Fatalf("external host change: saved=%v, err=%v", saved, err)
	}
	if result, err := settings.Save(ctx, reloaded, "project", []core.PluginSettingEdit{{ID: "flag", Value: json.RawMessage("true")}}); result.Committed || !errors.Is(err, configfile.ErrConflict) {
		t.Fatalf("stale save: committed=%v, err=%v", result.Committed, err)
	}
	current, err := settings.Load(ctx, id, i18n.English)
	if err != nil {
		t.Fatal(err)
	}
	// Reattaching the same session ID still invalidates the older editor.
	project.remote.binding.Detach()
	project.remote.binding.Attach(session)
	if result, err := settings.Save(ctx, current, "project", edits); result.Committed || !errors.Is(err, configfile.ErrConflict) {
		t.Fatalf("old attachment save: committed=%v, err=%v", result.Committed, err)
	}
	current, err = settings.Load(ctx, id, i18n.English)
	if err != nil {
		t.Fatal(err)
	}
	if result, err := settings.Save(ctx, current, "global", edits); err != nil || !result.Committed || result.Readback == nil {
		t.Fatalf("save client preference: committed=%v, readback=%v, err=%v", result.Committed, result.Readback != nil, err)
	}
	after, _, err := client.RemoteReadFile(ctx, session, hostFile)
	if err != nil || !bytes.Equal(after, external) {
		t.Fatalf("global or rejected save changed the host document: %q, %v", after, err)
	}
	if data, err := os.ReadFile(localFile); err != nil || string(data) != "local sentinel" {
		t.Fatalf("remote preference used the client placeholder: %q, %v", data, err)
	}
}

func connectVariantSSH(t *testing.T, client *core.Client, host string) (remoteHost, core.RemoteConnectResult) {
	t.Helper()
	bundle, err := remoteserver.Staged(os.Getenv("LITHE_REMOTE_SERVER_STAGE"))
	if err != nil {
		t.Fatal(err)
	}
	builds := make([]core.RemoteServerBuild, 0, len(bundle.Builds))
	for _, build := range bundle.Builds {
		builds = append(builds, core.RemoteServerBuild{Target: build.Target, Path: build.Path, SHA256: build.SHA256})
	}
	connection := remoteHost{ssh: core.SSHConnection{Host: host}}
	request := connection.request(builds, bundle.Version)
	request.InstallRoot = os.Getenv("LITHE_TEST_VARIANT_SSH_INSTALL_ROOT")
	if ssh := os.Getenv("LITHE_TEST_VARIANT_SSH_PROGRAM"); ssh != "" {
		data, err := json.Marshal(map[string]any{"version": 1, "sshProgram": ssh})
		if err != nil {
			t.Fatal(err)
		}
		preferences := string(data)
		request.Preferences = &preferences
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	connected, err := client.RemoteConnect(ctx, request)
	if err != nil || connected.Status != core.RemoteProbeConnected || connected.Session == nil {
		t.Fatalf("SSH connect: status=%s, err=%v, diagnostics=%s", connected.Status, err, connected.Diagnostics)
	}
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if _, err := client.RemoteDisconnect(ctx, connected.Session.ID, core.RemoteCloseEnd); err != nil {
			t.Errorf("disconnect SSH session: %v", err)
		}
	})
	return connection, connected
}

func buildLinuxVariantLanguageServer(t *testing.T) []byte {
	t.Helper()
	binary := buildLinuxSSHFixture(t, "test-language-server", "./testdata/remote_variant_server")
	data, err := os.ReadFile(binary)
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func buildLinuxSSHFixture(t *testing.T, name, source string) string {
	t.Helper()
	return buildLinuxSSHFixtureFor(t, name, source, "amd64")
}

// linuxSSHFixtureArch uses the connected host's architecture for executable test inputs.
func linuxSSHFixtureArch(t *testing.T, host core.RemoteConnectResult) string {
	t.Helper()
	platform := host.Host.PluginPlatform()
	if platform == nil || platform.OS != "linux" {
		t.Fatalf("target = %+v, want Linux", host.Host)
	}
	if platform.Arch == "x86_64" {
		return "amd64"
	}
	return platform.Arch
}

func buildLinuxSSHFixtureFor(t *testing.T, name, source, arch string) string {
	t.Helper()
	binary := filepath.Join(t.TempDir(), name)
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	command := exec.CommandContext(ctx, "go", "build", "-trimpath", "-ldflags=-s -w", "-o", binary, source)
	command.Env = append(os.Environ(), "GOOS=linux", "GOARCH="+arch, "CGO_ENABLED=0")
	if output, err := command.CombinedOutput(); err != nil {
		t.Fatalf("build Linux %s fixture %s: %v\n%s", arch, name, err, output)
	}
	return binary
}

func pluginProgramVariantArchive(t *testing.T, id, manifest, programPath string, program []byte) ([]byte, string) {
	t.Helper()
	return writeVariantArchive(t, id, []variantArchiveFile{
		{"plugin.json", []byte(manifest), 0o644},
		{"bin/backend", []byte("#!/bin/sh\nexit 1\n"), 0o755},
		{programPath, program, 0o755},
	})
}

type variantArchiveFile struct {
	name string
	data []byte
	mode os.FileMode
}

func writeVariantArchive(t *testing.T, root string, files []variantArchiveFile) ([]byte, string) {
	t.Helper()
	var data bytes.Buffer
	archive := zip.NewWriter(&data)
	for _, file := range files {
		header := &zip.FileHeader{Name: path.Join(root, file.name), Method: zip.Deflate}
		header.SetMode(file.mode)
		entry, err := archive.CreateHeader(header)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := entry.Write(file.data); err != nil {
			t.Fatal(err)
		}
	}
	if err := archive.Close(); err != nil {
		t.Fatal(err)
	}
	return data.Bytes(), fmt.Sprintf("%x", sha256.Sum256(data.Bytes()))
}
