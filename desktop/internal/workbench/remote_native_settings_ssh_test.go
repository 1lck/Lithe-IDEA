//go:build lithe_remote_e2e && (darwin || windows)

package workbench

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
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
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginsettings"
	"github.com/1lck/Lithe-IDEA/desktop/internal/plugintrust"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

func TestNativeToolSettingsUseTheSSHHost(t *testing.T) {
	host := os.Getenv("LITHE_TEST_VARIANT_SSH_HOST")
	if host == "" {
		t.Skip("set LITHE_TEST_VARIANT_SSH_HOST to a disposable Linux OpenSSH target")
	}
	const id = "io.github.example.remote-native-settings-fixture"
	const name = "Native settings SSH fixture"
	const action = "nativeConfig"
	client := core.NewClient()
	hostConnection, connected := connectVariantSSH(t, client, host)
	session := connected.Session.ID
	platform := connected.Host.PluginPlatform()
	if platform == nil || platform.OS != "linux" || !path.IsAbs(connected.Session.HomeDirectory) {
		t.Fatalf("the fixture requires a Linux session with a reported home directory: %+v", connected.Host)
	}
	arch := linuxSSHFixtureArch(t, connected)
	helperFile := buildLinuxSSHFixtureFor(t, "settings-helper", "./testdata/remote_settings_helper", arch)
	helper, err := os.ReadFile(helperFile)
	if err != nil {
		t.Fatal(err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	directory, err := client.RemoteTempDirectory(ctx, session, "lithe-native-settings-test")
	if err != nil || !path.IsAbs(directory) {
		t.Fatalf("create host fixture: path=%q, err=%v", directory, err)
	}
	homeName := ".lithe-native-settings-" + rand.Text()
	homeFile := path.Join(connected.Session.HomeDirectory, homeName)
	defer func() {
		cleanup, cancel := context.WithTimeout(context.Background(), 8*time.Second)
		defer cancel()
		if err := client.RemoteHostRequest(cleanup, session, "fs.remove", map[string]string{"path": homeFile}, nil); err != nil && !missingSSHFixture(err) {
			t.Errorf("remove test home file: %v", err)
		}
		if err := client.RemoteRemove(cleanup, session, directory, true); err != nil {
			t.Errorf("release host fixture: %v", err)
		}
	}()
	projectFile, defaultsFile := path.Join(directory, "project.fixture"), path.Join(directory, "defaults.fixture")
	for file, value := range map[string]string{projectFile: "initial-project", defaultsFile: "initial-default"} {
		if _, saved, err := client.RemoteWriteFile(ctx, session, file, []byte(value), nil); err != nil || !saved {
			t.Fatalf("write host fixture: saved=%v, err=%v", saved, err)
		}
	}

	root := filepath.Join(t.TempDir(), "workspace")
	writeFixture(t, root, map[string]string{"project.fixture": "desktop-sentinel"})
	preferences := t.TempDir()
	writeFixture(t, preferences, map[string]string{settingsFile: `{"theme":"dark"}`})
	h := newHarnessWithOptions(t, Options{
		Kernel: &testKernel{Client: client}, PluginKernel: client, PluginRoot: t.TempDir(),
		Store: store.At(preferences), Languages: []string{"en"},
	})
	installNativeSettingsFixture(t, h, ctx, id, action, homeName, helper, *platform)
	h.app.openRemoteProject(remoteTarget{
		connectionID: "native-settings-ssh", name: name, host: hostConnection, platform: platform,
		session: *connected.Session, remoteRoot: directory, root: root, trusted: true,
	})
	project := h.app.project
	if project == nil || project.remote == nil {
		t.Fatal("the SSH project did not open")
	}
	settings := pluginSettingsSources{app: h.app}
	editor, err := settings.Load(ctx, id, i18n.English)
	if err != nil {
		t.Fatalf("open plugin settings: %v", err)
	}
	if editor.Snapshot.ProjectConnectionName() != name {
		t.Fatalf("connection name = %q, want %q", editor.Snapshot.ProjectConnectionName(), name)
	}
	load := func() pluginsettings.SourceEditor {
		t.Helper()
		result, err := settings.Action(ctx, editor, action, true)
		if err != nil || result.Sources == nil || !result.Sources.IsRemote() {
			t.Fatalf("load native settings from SSH: %v", err)
		}
		return *result.Sources
	}
	checkFile := func(file, want string) {
		t.Helper()
		data, _, err := client.RemoteReadFile(ctx, session, file)
		if err != nil || string(data) != want {
			t.Fatalf("read host fixture %q: got %q, want %q, err=%v", path.Base(file), data, want, err)
		}
	}
	checkMissing := func(file string) {
		t.Helper()
		if _, err := client.RemoteStat(ctx, session, file); !missingSSHFixture(err) {
			t.Fatalf("fixture path should be absent: err=%v", err)
		}
	}
	checkStaging := func(marker string, count int, operation string) {
		t.Helper()
		data, _, err := client.RemoteReadFile(ctx, session, path.Join(directory, marker))
		if err != nil {
			t.Fatalf("read helper marker: %v", err)
		}
		lines := strings.Split(string(data), "\n")
		if operation != "" {
			if lines[0] != operation {
				t.Fatalf("read operation = %q, want %q", lines[0], operation)
			}
			lines = lines[1:]
		}
		if len(lines) != count {
			t.Fatalf("staging paths = %d, want %d", len(lines), count)
		}
		for _, file := range lines {
			if !path.IsAbs(file) {
				t.Fatal("the helper did not receive an absolute staging path")
			}
			checkMissing(path.Dir(file))
		}
	}
	edit := func(source, text string) core.SourceSettingsEdits {
		return core.SourceSettingsEdits{SourceID: source, Values: map[string]core.SourceSettingInput{"name": {Text: text}}}
	}

	source := load()
	checkMissing(homeFile)
	wantPaths := map[string]string{"project": projectFile, "user": homeFile, "defaults": defaultsFile}
	if len(source.State.Snapshot.Sources) != len(wantPaths) {
		t.Fatalf("expected %d projected sources", len(wantPaths))
	}
	for _, row := range source.State.Snapshot.Sources {
		if source.DisplayPath(row) != wantPaths[row.ID] || row.Writable != (row.ID != "defaults") {
			t.Fatalf("wrong host path or editability for %q: %q, writable=%v", row.ID, source.DisplayPath(row), row.Writable)
		}
	}
	if _, err := settings.SaveSources(ctx, editor, action, source, []core.SourceSettingsEdits{edit("defaults", "blocked")}); err == nil {
		t.Fatal("the settings worker accepted an edit to a read-only source")
	}
	checkMissing(path.Join(directory, "last-edit"))
	source, err = settings.SaveSources(ctx, editor, action, source, []core.SourceSettingsEdits{
		edit("project", "saved-project"), edit("user", "saved-user"),
	})
	if err != nil {
		t.Fatalf("save remote settings: %v", err)
	}
	if source.State.Inputs["project"]["name"].Text != "saved-project" || source.State.Inputs["user"]["name"].Text != "saved-user" {
		t.Fatal("the settings worker did not return the saved values from the host")
	}
	checkFile(projectFile, "saved-project")
	checkFile(homeFile, "saved-user")
	checkFile(defaultsFile, "initial-default")
	checkStaging("last-read", 1, "readAfterSave")
	checkStaging("last-edit", 2, "")

	if _, err := settings.SaveSources(ctx, editor, action, source, []core.SourceSettingsEdits{edit("project", "bad-receipt")}); err == nil || errors.Is(err, pluginsettings.ErrSourcesCommitted) {
		t.Fatalf("a malformed receipt was not refused before publication: %v", err)
	}
	checkStaging("last-edit", 2, "")
	checkFile(projectFile, "saved-project")
	_, version, err := client.RemoteReadFile(ctx, session, projectFile)
	if err != nil {
		t.Fatalf("read project settings revision: %v", err)
	}
	if _, saved, err := client.RemoteWriteFile(ctx, session, projectFile, []byte("external-project"), &version); err != nil || !saved {
		t.Fatalf("write external edit: saved=%v, err=%v", saved, err)
	}
	if _, err := settings.SaveSources(ctx, editor, action, source, []core.SourceSettingsEdits{edit("project", "old-projection")}); !errors.Is(err, configfile.ErrConflict) {
		t.Fatalf("save over external edit: %v", err)
	}
	source = load()
	project.remote.binding.Detach()
	project.remote.binding.Attach(session)
	if _, err := settings.SaveSources(ctx, editor, action, source, []core.SourceSettingsEdits{edit("user", "old-connection")}); !errors.Is(err, configfile.ErrConflict) {
		t.Fatalf("save from previous attachment: %v", err)
	}
	checkFile(projectFile, "external-project")
	checkFile(homeFile, "saved-user")
	if data, err := os.ReadFile(filepath.Join(root, "project.fixture")); err != nil || string(data) != "desktop-sentinel" {
		t.Fatalf("remote settings changed the desktop fixture: %q, %v", data, err)
	}
}

func missingSSHFixture(err error) bool {
	var failure *core.Error
	return errors.As(err, &failure) && failure.Code == core.CodeWorkspaceNotFound
}

func installNativeSettingsFixture(t *testing.T, h *harness, ctx context.Context, id, action, homeName string, helper []byte, platform core.RemotePlatform) {
	t.Helper()
	const version = "1.0.0"
	const helperPath = "bin/settings-helper"
	const repository = "https://github.com/example/native-settings"
	const indexURL = "https://raw.githubusercontent.com/example/lithe-plugins/HEAD/lithe-plugin-index.json"
	const localURL = repository + "/releases/download/1.0.0/desktop.zip"
	const remoteURL = repository + "/releases/download/1.0.0/linux.zip"
	const requires = `{"backend":0,"languages":0,"settings":0,"sourceSettings":2}`
	manifest := fmt.Sprintf(`{
		"schemaVersion":0, "pluginAPIVersion":0, "id":%q, "version":%q, "displayName":"Native settings fixture",
		"requires":%s, "vendor":{"id":"io.github.example","displayName":"Fixture","signatureRequirement":"none"},
		"permissions":["backend.launch","workspace.metadata"],
		"languages":[{"id":"native-fixture","displayName":"Native fixture","fileExtensions":["native-fixture"]}],
		"backend":{"launch":{"kind":"packaged","path":"bin/backend"}},
		"settingActions":[{"id":%q,"title":"Native fixture settings","function":"fixture.read",
			"sourceEditor":{"editFunction":"fixture.edit","remoteHelper":{"executable":%q,"arguments":[%q]}}}]
	}`, id, version, requires, action, helperPath, homeName)
	archive, localDigest := pluginProgramVariantArchive(t, id, manifest, helperPath, []byte("#!/bin/sh\nexit 1\n"))
	linuxArchive, remoteDigest := pluginProgramVariantArchive(t, id, manifest, helperPath, helper)
	linuxPlatform := "linux-arm64"
	if platform.Arch == "x86_64" {
		linuxPlatform = "linux-x64"
	}
	index := fmt.Sprintf(`{"schemaVersion":0,"plugins":[{
		"id":%q,"name":"Native settings fixture","author":"Fixture","repository":%q,
		"description":"Fixture for remote tool settings.","license":"MIT","versions":[{
			"version":%q,"pluginAPIVersion":0,"releaseDate":"2026-10-01","requires":%s,"downloads":[
				{"platforms":[%q],"downloadURL":%q,"sha256":%q},
				{"platforms":[%q],"downloadURL":%q,"sha256":%q}
		]}]}]}`, id, repository, version, requires, marketplace.CurrentPlatform(), localURL, localDigest, linuxPlatform, remoteURL, remoteDigest)
	service := h.app.plugins
	service.RuntimeDownloader = marketplace.NewArchiveDownloader(&http.Client{
		Transport: pluginArchiveTransport(func(request *http.Request) (*http.Response, error) {
			var data []byte
			switch request.URL.String() {
			case indexURL:
				data = []byte(index)
			case remoteURL:
				data = linuxArchive
			default:
				return nil, fmt.Errorf("unexpected fixture request to %s", request.URL)
			}
			return &http.Response{StatusCode: http.StatusOK, Header: make(http.Header),
				Body: io.NopCloser(bytes.NewReader(data)), ContentLength: int64(len(data)), Request: request}, nil
		}),
	})
	file := filepath.Join(t.TempDir(), "desktop.zip")
	if err := os.WriteFile(file, archive, 0o600); err != nil {
		t.Fatal(err)
	}
	plan, err := h.app.preparePlugin(ctx, plugininstall.Request{
		ArchivePath: file, Root: service.Root, Source: plugintrust.Marketplace,
		ArchiveSHA256: localDigest, MarketplaceIndexURL: indexURL, MarketplaceRepository: repository,
		ExpectedID: id, ExpectedVersion: version,
	})
	if err != nil {
		t.Fatalf("prepare native settings fixture: %v", err)
	}
	defer func() {
		if err := service.Installer.Discard(plan); err != nil {
			t.Errorf("discard native settings package staging: %v", err)
		}
	}()
	reviewed := false
	for _, program := range plan.Review.NewPrograms {
		var entry struct {
			Kind       string `json:"kind"`
			Executable string `json:"executable"`
		}
		if err := json.Unmarshal(program, &entry); err != nil {
			t.Fatal(err)
		}
		reviewed = reviewed || (entry.Kind == "settingsHelper" && entry.Executable == helperPath)
	}
	if !plan.NeedsApproval() || !reviewed {
		t.Fatal("the helper was not included in the installation approval")
	}
	if _, err := service.Installer.Commit(plan); err != nil {
		t.Fatal(err)
	}
	if _, err := service.Manager.EnableInstalled(id); err != nil {
		t.Fatal(err)
	}
}
