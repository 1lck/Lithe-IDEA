package pluginservice

import (
	"archive/zip"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/marketplace"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginbackend"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginmanager"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginpkg"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/1lck/Lithe-IDEA/desktop/internal/toolchain"
)

// runtimeResolverKernel runs the actual Core contract and native preparation, replacing only
// the plugin process with an event-driven resolver. No concrete plugin or system tool is used.
type runtimeResolverKernel struct {
	*core.Client
	mu             sync.Mutex
	queues         map[string]chan core.BackendEvent
	external       map[string]string
	canonicalHomes bool
	settingsHome   bool
	start          func(context.Context, core.PluginBackendStart) error
	stop           func(context.Context, string) error
	destroy        func(context.Context, string) error
	waitError      func(string) error
	starts         atomic.Int32
	stops          atomic.Int32
}

func (k *runtimeResolverKernel) StartPluginBackend(ctx context.Context, request core.PluginBackendStart) (core.PluginBackendStarted, error) {
	if k.start != nil {
		if err := k.start(ctx, request); err != nil {
			return core.PluginBackendStarted{}, err
		}
	}
	id := fmt.Sprintf("runtime-check-%d", k.starts.Add(1))
	queue := make(chan core.BackendEvent, 8)
	queue <- core.BackendEvent{Type: "stateChanged", State: "ready"}
	queue <- core.BackendEvent{Type: "functionsChanged", Result: json.RawMessage(`{"functions":["fixture.resolve"]}`)}
	k.mu.Lock()
	k.queues[id] = queue
	k.mu.Unlock()
	return core.PluginBackendStarted{SessionID: id}, nil
}

func (k *runtimeResolverKernel) StartPluginLanguageServer(ctx context.Context, request core.PluginBackendStart) (core.PluginBackendStarted, error) {
	request.Role = "language-server"
	return k.StartPluginBackend(ctx, request)
}

func (k *runtimeResolverKernel) WaitBackendEvents(ctx context.Context, session string, _ int) ([]core.BackendEvent, error) {
	if k.waitError != nil {
		if err := k.waitError(session); err != nil {
			return nil, err
		}
	}
	k.mu.Lock()
	queue := k.queues[session]
	k.mu.Unlock()
	if queue == nil {
		return nil, errors.New("unknown fixture session")
	}
	select {
	case event := <-queue:
		return []core.BackendEvent{event}, nil
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

func (k *runtimeResolverKernel) InvokePluginFunctionInContext(ctx context.Context, session, operation, _, function string, params, _ json.RawMessage, _ int) (string, error) {
	if function != "fixture.resolve" {
		return "", errors.New("unexpected preparation function")
	}
	var request struct {
		Candidates   map[string]string               `json:"candidates"`
		Dependencies []core.ManagedRuntimeDependency `json:"dependencies"`
		Settings     map[string]json.RawMessage      `json:"settings"`
	}
	if err := json.Unmarshal(params, &request); err != nil {
		return "", err
	}
	answer := core.ManagedRuntimeResolution{Runtimes: []core.ManagedRuntimeInstallation{}, Missing: []string{}}
	for _, dependency := range request.Dependencies {
		home := request.Candidates[dependency.ID]
		if k.settingsHome {
			if err := json.Unmarshal(request.Settings["runtimeHome"], &home); err != nil {
				return "", err
			}
		}
		if home == "" {
			home = k.external[dependency.ID]
		}
		body, err := os.ReadFile(filepath.Join(home, "payload"))
		if home != "" && err == nil && string(body) == "usable" {
			if k.canonicalHomes {
				home, err = filepath.EvalSymlinks(home)
				if err != nil {
					return "", err
				}
			}
			answer.Runtimes = append(answer.Runtimes, core.ManagedRuntimeInstallation{ID: dependency.ID, Home: home, Version: dependency.Version})
		} else {
			answer.Missing = append(answer.Missing, dependency.ID)
		}
	}
	value, err := json.Marshal(map[string]any{"value": answer})
	if err != nil {
		return "", err
	}
	k.mu.Lock()
	queue := k.queues[session]
	k.mu.Unlock()
	select {
	case queue <- core.BackendEvent{Type: "requestCompleted", OperationID: operation, Result: value}:
		return operation, nil
	case <-ctx.Done():
		return "", ctx.Err()
	}
}

func (k *runtimeResolverKernel) StopPluginBackend(ctx context.Context, session string) error {
	k.stops.Add(1)
	if k.stop != nil {
		return k.stop(ctx, session)
	}
	return nil
}
func (k *runtimeResolverKernel) DestroyPluginBackend(ctx context.Context, session string) error {
	if k.destroy != nil {
		if err := k.destroy(ctx, session); err != nil {
			return err
		}
	}
	k.mu.Lock()
	defer k.mu.Unlock()
	if k.queues[session] == nil {
		return errors.New("unknown fixture session")
	}
	delete(k.queues, session)
	return nil
}
func (k *runtimeResolverKernel) SetDetailedDiagnostics(context.Context, string, bool) error {
	return nil
}

type runtimeTransport func(*http.Request) (*http.Response, error)

func (f runtimeTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func runtimeFixture(t *testing.T) (json.RawMessage, []byte, string) {
	t.Helper()
	var archive bytes.Buffer
	writer := zip.NewWriter(&archive)
	file, err := writer.Create("payload")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := file.Write([]byte("usable")); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	hash := sha256.Sum256(archive.Bytes())
	deps := make([]any, 0, 2)
	for _, id := range []string{"alpha", "beta"} {
		deps = append(deps, map[string]any{"id": id, "version": "1.0", "artifacts": []any{map[string]any{
			"os": toolchain.PlatformName(runtime.GOOS), "arch": core.PluginArchitecture(), "url": "https://runtimes.example.test/" + id + ".zip",
			"sha256": hex.EncodeToString(hash[:]), "archive": "zip",
		}}})
	}
	manifest, err := json.Marshal(map[string]any{
		"schemaVersion": 0, "pluginAPIVersion": 0, "id": "dev.lithe.test.managed-environment", "displayName": "Environment fixture", "version": "1.0.0",
		"requires":        map[string]int{"backend": 0, "managedRuntimes": 0},
		"vendor":          map[string]string{"id": "org.example", "displayName": "Example", "signatureRequirement": "publisherPackage"},
		"permissions":     []string{"backend.launch", "runtimes.install"},
		"backend":         map[string]any{"launch": map[string]string{"kind": "packaged", "path": "bin/resolver"}},
		"managedRuntimes": map[string]any{"resolve": map[string]any{"function": "fixture.resolve", "timeoutMilliseconds": 5000}, "dependencies": deps},
	})
	if err != nil {
		t.Fatal(err)
	}
	packageRoot := t.TempDir()
	if err := os.MkdirAll(filepath.Join(packageRoot, "bin"), 0o700); err != nil {
		t.Fatal(err)
	}
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	image, err := os.ReadFile(executable)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(packageRoot, "bin", "resolver"), image, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(packageRoot, "plugin.json"), manifest, 0o600); err != nil {
		t.Fatal(err)
	}
	return manifest, archive.Bytes(), packageRoot
}

func TestRuntimePreparationReusesExternalAndManagedHomesAcrossUpdates(t *testing.T) {
	manifest, archive, packageRoot := runtimeFixture(t)
	external := t.TempDir()
	if err := os.WriteFile(filepath.Join(external, "payload"), []byte("usable"), 0o600); err != nil {
		t.Fatal(err)
	}
	kernel := &runtimeResolverKernel{Client: core.NewClient(), queues: make(map[string]chan core.BackendEvent), external: map[string]string{"alpha": external}}
	service, err := Open(kernel, store.At(t.TempDir()), t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	var downloads atomic.Int32
	service.RuntimeDownloader = marketplace.NewArchiveDownloader(&http.Client{Transport: runtimeTransport(func(request *http.Request) (*http.Response, error) {
		downloads.Add(1)
		if request.URL.Path != "/beta.zip" {
			return nil, errors.New("eligible external dependency was downloaded")
		}
		return &http.Response{StatusCode: 200, Header: make(http.Header), Body: io.NopCloser(bytes.NewReader(archive)), ContentLength: int64(len(archive)), Request: request}, nil
	})})
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	first, err := service.EnsureRuntimes(ctx, manifest, packageRoot, "dev.lithe.test.managed-environment", "1.0.0", true, nil)
	if err != nil {
		t.Fatal(err)
	}
	if downloads.Load() != 1 || first.Runtimes["alpha"].Home != external || len(first.Runtimes) != 2 {
		t.Fatalf("first environment=%+v downloads=%d", first, downloads.Load())
	}
	updated := bytes.Replace(manifest, []byte(`"version":"1.0.0"`), []byte(`"version":"1.1.0"`), 1)
	second, err := service.EnsureRuntimes(ctx, updated, packageRoot, "dev.lithe.test.managed-environment", "1.1.0", true, nil)
	if err != nil || downloads.Load() != 1 || second.Runtimes["beta"].Home != first.Runtimes["beta"].Home {
		t.Fatalf("update=%+v downloads=%d error=%v", second, downloads.Load(), err)
	}
	if err := os.WriteFile(filepath.Join(first.Runtimes["beta"].Home, "payload"), []byte("broken"), 0o600); err != nil {
		t.Fatal(err)
	}
	repaired, err := service.EnsureRuntimes(ctx, updated, packageRoot, "dev.lithe.test.managed-environment", "1.1.0", false, nil)
	if err != nil || downloads.Load() != 1 || repaired.Runtimes["beta"].Home == first.Runtimes["beta"].Home {
		t.Fatalf("offline repair=%+v downloads=%d error=%v", repaired, downloads.Load(), err)
	}
	if kernel.starts.Load() != 3 || kernel.stops.Load() != 3 {
		t.Fatalf("preflight process leak: starts=%d stops=%d", kernel.starts.Load(), kernel.stops.Load())
	}
	after, err := os.ReadFile(filepath.Join(packageRoot, "plugin.json"))
	if err != nil || !bytes.Equal(after, manifest) {
		t.Fatal("preparation modified the approved package")
	}
}

func TestOldPluginDoesNotStartRuntimePreparation(t *testing.T) {
	service := &Service{}
	if _, err := service.EnsureRuntimes(context.Background(), json.RawMessage(`{"id":"dev.lithe.test.legacy"}`), "", "", "", true, nil); err != nil {
		t.Fatal(err)
	}
}

func runtimePayload(t *testing.T) string {
	t.Helper()
	directory := t.TempDir()
	if err := os.WriteFile(filepath.Join(directory, "payload"), []byte("usable"), 0o600); err != nil {
		t.Fatal(err)
	}
	return directory
}

func installRuntimeFixture(t *testing.T, root, packageRoot string, manifest json.RawMessage) string {
	t.Helper()
	directory := filepath.Join(root, "dev.lithe.test.managed-environment", "1.0.0")
	if err := os.MkdirAll(filepath.Dir(directory), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(packageRoot, pluginpkg.ManifestFile), manifest, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(packageRoot, directory); err != nil {
		t.Fatal(err)
	}
	return directory
}

func waitRuntimeSignal(t *testing.T, ctx context.Context, done <-chan struct{}, what string) {
	t.Helper()
	select {
	case <-done:
	case <-ctx.Done():
		t.Fatalf("waiting for %s: %v", what, ctx.Err())
	}
}

func joinRuntimeWorker(t *testing.T, done <-chan struct{}, what string) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	select {
	case <-done:
	case <-ctx.Done():
		t.Errorf("cleanup did not finish %s: %v", what, ctx.Err())
	}
}

func TestRuntimePreparationAcceptsCanonicalHomeThroughSymlink(t *testing.T) {
	manifest, archive, packageRoot := runtimeFixture(t)
	root := t.TempDir()
	alias := filepath.Join(t.TempDir(), "plugin-root")
	if err := os.Symlink(root, alias); err != nil {
		if runtime.GOOS == "windows" {
			t.Skipf("symlink privilege unavailable: %v", err)
		}
		t.Fatal(err)
	}
	kernel := &runtimeResolverKernel{Client: core.NewClient(), queues: make(map[string]chan core.BackendEvent), canonicalHomes: true}
	service, err := Open(kernel, store.At(t.TempDir()), alias)
	if err != nil {
		t.Fatal(err)
	}
	var downloads atomic.Int32
	service.RuntimeDownloader = marketplace.NewArchiveDownloader(&http.Client{Transport: runtimeTransport(func(request *http.Request) (*http.Response, error) {
		downloads.Add(1)
		return &http.Response{StatusCode: 200, Header: make(http.Header), Body: io.NopCloser(bytes.NewReader(archive)), ContentLength: int64(len(archive)), Request: request}, nil
	})})
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	environment, err := service.EnsureRuntimes(ctx, manifest, packageRoot, "dev.lithe.test.managed-environment", "1.0.0", true, nil)
	if err != nil || downloads.Load() != 2 || len(environment.Runtimes) != 2 {
		t.Fatalf("canonical managed homes=%+v downloads=%d error=%v", environment, downloads.Load(), err)
	}
	for _, installation := range environment.Runtimes {
		canonical, err := filepath.EvalSymlinks(installation.Home)
		if err != nil || canonical != installation.Home {
			t.Fatalf("resolver did not return its canonical home: %q, %v", installation.Home, err)
		}
	}
}

func TestRuntimePreparationUsesEffectiveWorkspaceSettingsSnapshot(t *testing.T) {
	manifest, _, packageRoot := runtimeFixture(t)
	globalHome, projectHome := runtimePayload(t), runtimePayload(t)
	var declaration map[string]any
	if err := json.Unmarshal(manifest, &declaration); err != nil {
		t.Fatal(err)
	}
	declaration["requires"].(map[string]any)["settings"] = 0
	declaration["settings"] = []any{map[string]any{"id": "runtimeHome", "type": "directory", "title": "Runtime home", "default": "", "scope": "project"}}
	manifest, err := json.Marshal(declaration)
	if err != nil {
		t.Fatal(err)
	}
	kernel := &runtimeResolverKernel{Client: core.NewClient(), queues: make(map[string]chan core.BackendEvent), settingsHome: true}
	service, err := Open(kernel, store.At(t.TempDir()), t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	service.RuntimeDownloader = marketplace.NewArchiveDownloader(&http.Client{Transport: runtimeTransport(func(*http.Request) (*http.Response, error) {
		return nil, errors.New("effective settings selected a reusable external home; no download is expected")
	})})
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	snapshot, err := service.Settings.Load(ctx, manifest, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	globalValue, err := json.Marshal(globalHome)
	if err != nil {
		t.Fatal(err)
	}
	global, err := service.Settings.Save(ctx, snapshot, "global", []core.PluginSettingEdit{{ID: "runtimeHome", Value: globalValue}}, nil)
	if err != nil || global.Readback == nil {
		t.Fatalf("global settings save: %+v, %v", global, err)
	}
	value, err := json.Marshal(projectHome)
	if err != nil {
		t.Fatal(err)
	}
	saved, err := service.Settings.Save(ctx, *global.Readback, "project", []core.PluginSettingEdit{{ID: "runtimeHome", Value: value}}, nil)
	if err != nil || saved.Readback == nil {
		t.Fatalf("workspace settings save: %+v, %v", saved, err)
	}
	environment, err := service.EnsureRuntimesWithSettings(ctx, manifest, packageRoot, "dev.lithe.test.managed-environment", "1.0.0", false, saved.Readback.State, nil)
	if err != nil || environment.Runtimes["alpha"].Home != projectHome || environment.Runtimes["beta"].Home != projectHome {
		t.Fatalf("workspace preparation=%+v, error=%v", environment, err)
	}
	installation, err := service.EnsureRuntimes(ctx, manifest, packageRoot, "dev.lithe.test.managed-environment", "1.0.0", true, nil)
	if err != nil || installation.Runtimes["alpha"].Home != globalHome {
		t.Fatalf("installation must use global settings: %+v, %v", installation, err)
	}
}

func TestUninstallCancelsOtherWindowPreparationBeforeRemovingFiles(t *testing.T) {
	manifest, _, packageRoot := runtimeFixture(t)
	root, preferences := t.TempDir(), store.At(t.TempDir())
	kernel := &runtimeResolverKernel{Client: core.NewClient(), queues: make(map[string]chan core.BackendEvent)}
	owner, err := Open(kernel, preferences, root)
	if err != nil {
		t.Fatal(err)
	}
	other, err := OpenAnother(kernel, preferences, root)
	if err != nil {
		t.Fatal(err)
	}
	installed := installRuntimeFixture(t, root, packageRoot, manifest)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	downloadStarted, downloadCancelled, releaseDownload := make(chan struct{}), make(chan struct{}), make(chan struct{})
	var releaseOnce sync.Once
	release := func() { releaseOnce.Do(func() { close(releaseDownload) }) }
	other.RuntimeDownloader = marketplace.NewArchiveDownloader(&http.Client{Transport: runtimeTransport(func(request *http.Request) (*http.Response, error) {
		close(downloadStarted)
		select {
		case <-request.Context().Done():
			close(downloadCancelled)
		case <-ctx.Done():
			return nil, ctx.Err()
		}
		select {
		case <-releaseDownload:
			return nil, request.Context().Err()
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	})})
	preparationDone := make(chan struct{})
	var preparationErr error
	go func() {
		defer close(preparationDone)
		_, preparationErr = other.EnsureRuntimes(ctx, manifest, installed, "dev.lithe.test.managed-environment", "1.0.0", true, nil)
	}()
	t.Cleanup(func() { cancel(); release(); joinRuntimeWorker(t, preparationDone, "cancelled preparation") })
	waitRuntimeSignal(t, ctx, downloadStarted, "dependency download")
	uninstallDone := make(chan struct{})
	var uninstallErr error
	go func() {
		defer close(uninstallDone)
		uninstallErr = owner.Uninstall(ctx, "dev.lithe.test.managed-environment", nil)
	}()
	t.Cleanup(func() { cancel(); release(); joinRuntimeWorker(t, uninstallDone, "uninstall") })
	waitRuntimeSignal(t, ctx, downloadCancelled, "uninstall cancelling the other window")
	if _, err := os.Stat(installed); err != nil {
		t.Fatalf("package removed before preparation released its files: %v", err)
	}
	if _, _, err := other.BeginRuntimeInstallation(ctx, "dev.lithe.test.managed-environment"); !errors.Is(err, ErrRuntimeBusy) {
		t.Fatalf("approved installation bypassed ongoing uninstall: %v", err)
	}
	release()
	waitRuntimeSignal(t, ctx, preparationDone, "preparation cleanup")
	waitRuntimeSignal(t, ctx, uninstallDone, "uninstall completion")
	if uninstallErr != nil || !errors.Is(preparationErr, context.Canceled) {
		t.Fatalf("uninstall=%v preparation=%v", uninstallErr, preparationErr)
	}
	if kernel.starts.Load() != 1 || kernel.stops.Load() != 1 {
		t.Fatalf("checker process leak: starts=%d stops=%d", kernel.starts.Load(), kernel.stops.Load())
	}
	if _, err := os.Stat(pluginpkg.StateRoot(root, "dev.lithe.test.managed-environment")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("preparation recreated removed state: %v", err)
	}
	if err := other.AllowRuntimePreparation("dev.lithe.test.managed-environment"); err != nil {
		t.Fatalf("completed uninstall did not permit a later explicit installation: %v", err)
	}
}

func TestRuntimePreparationOwnsLanguageServerStartUntilCancelledProcessStops(t *testing.T) {
	manifest, archive, packageRoot := runtimeFixture(t)
	var declaration map[string]any
	if err := json.Unmarshal(manifest, &declaration); err != nil {
		t.Fatal(err)
	}
	requirements := declaration["requires"].(map[string]any)
	requirements["languages"], requirements["languageServers"] = 0, 0
	declaration["permissions"] = []string{"backend.launch", "runtimes.install", "languageServer.launch"}
	declaration["activationEvents"] = []string{"onLanguage:fixture"}
	declaration["languages"] = []any{map[string]any{"id": "fixture", "displayName": "Fixture", "fileExtensions": []string{"fixture"}}}
	declaration["languageServers"] = []any{map[string]any{"languageID": "fixture", "launch": map[string]string{"kind": "packaged", "path": "bin/resolver"}}}
	manifest, err := json.Marshal(declaration)
	if err != nil {
		t.Fatal(err)
	}
	kernel := &runtimeResolverKernel{Client: core.NewClient(), queues: make(map[string]chan core.BackendEvent)}
	service, err := Open(kernel, store.At(t.TempDir()), t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	installed := installRuntimeFixture(t, service.Root, packageRoot, manifest)
	waitCtx, cancelWait := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancelWait()
	work, cancelWork := context.WithCancel(context.Background())
	defer cancelWork()
	startEntered, startCancelled, releaseStart := make(chan struct{}), make(chan struct{}), make(chan struct{})
	var releaseOnce sync.Once
	release := func() { releaseOnce.Do(func() { close(releaseStart) }) }
	var downloadHasDeadline, processHasBudget atomic.Bool
	service.RuntimeDownloader = marketplace.NewArchiveDownloader(&http.Client{Transport: runtimeTransport(func(request *http.Request) (*http.Response, error) {
		if _, present := request.Context().Deadline(); present {
			downloadHasDeadline.Store(true)
		}
		return &http.Response{StatusCode: 200, Header: make(http.Header), Body: io.NopCloser(bytes.NewReader(archive)), ContentLength: int64(len(archive)), Request: request}, nil
	})})
	kernel.start = func(ctx context.Context, request core.PluginBackendStart) error {
		if request.Role != "language-server" {
			return nil
		}
		deadline, present := ctx.Deadline()
		processHasBudget.Store(present && time.Until(deadline) > 0 && time.Until(deadline) <= 2*time.Minute)
		close(startEntered)
		select {
		case <-ctx.Done():
			close(startCancelled)
		case <-waitCtx.Done():
			return waitCtx.Err()
		}
		// Native process creation can complete after cancellation. The service
		// must still stop that process before uninstall may remove the executable.
		select {
		case <-releaseStart:
			return nil
		case <-waitCtx.Done():
			return waitCtx.Err()
		}
	}
	entry := pluginmanager.Entry{Installed: pluginpkg.Installed{ID: "dev.lithe.test.managed-environment", Version: "1.0.0", Path: installed}, Enabled: true}
	startDone := make(chan struct{})
	var startErr error
	go func() {
		defer close(startDone)
		_, startErr = service.StartLanguageServer(work, []pluginmanager.Entry{entry}, "fixture", BackendRequest{Architecture: core.PluginArchitecture(), ProjectCodeAllowed: true})
	}()
	t.Cleanup(func() { cancelWork(); release(); joinRuntimeWorker(t, startDone, "late language-server start") })
	select {
	case <-startEntered:
	case <-startDone:
		t.Fatalf("language-server start ended before native launch: %v", startErr)
	case <-waitCtx.Done():
		t.Fatalf("waiting for native language-server start: %v", waitCtx.Err())
	}
	uninstallDone := make(chan struct{})
	var uninstallErr error
	go func() { defer close(uninstallDone); uninstallErr = service.Uninstall(waitCtx, entry.Installed.ID, nil) }()
	t.Cleanup(func() { cancelWork(); release(); joinRuntimeWorker(t, uninstallDone, "language-server uninstall") })
	waitRuntimeSignal(t, waitCtx, startCancelled, "native start cancellation")
	if _, err := os.Stat(installed); err != nil {
		t.Fatalf("uninstall removed an in-flight process image: %v", err)
	}
	release()
	waitRuntimeSignal(t, waitCtx, startDone, "cancelled process disposal")
	waitRuntimeSignal(t, waitCtx, uninstallDone, "safe file removal")
	if uninstallErr != nil || !errors.Is(startErr, context.Canceled) || kernel.starts.Load() != 2 || kernel.stops.Load() != 2 {
		t.Fatalf("uninstall=%v start=%v starts=%d stops=%d", uninstallErr, startErr, kernel.starts.Load(), kernel.stops.Load())
	}
	if downloadHasDeadline.Load() || !processHasBudget.Load() {
		t.Fatalf("download total deadline=%v process bounded=%v", downloadHasDeadline.Load(), processHasBudget.Load())
	}
}

func TestRuntimeInstallationAdmissionCoversPublicationAfterPreparation(t *testing.T) {
	manifest, _, packageRoot := runtimeFixture(t)
	kernel := &runtimeResolverKernel{Client: core.NewClient(), queues: make(map[string]chan core.BackendEvent)}
	service, err := Open(kernel, store.At(t.TempDir()), t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	installed := installRuntimeFixture(t, service.Root, packageRoot, manifest)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	work, finish, err := service.BeginRuntimeInstallation(ctx, "dev.lithe.test.managed-environment")
	if err != nil {
		t.Fatal(err)
	}
	finishOnce := sync.OnceValue(finish)
	release := func() {
		if err := finishOnce(); err != nil {
			t.Error(err)
		}
	}
	t.Cleanup(release)
	// Preparation has finished, but the approved operation still owns publication.
	uninstallDone := make(chan struct{})
	var uninstallErr error
	go func() {
		defer close(uninstallDone)
		uninstallErr = service.Uninstall(ctx, "dev.lithe.test.managed-environment", nil)
	}()
	t.Cleanup(func() { cancel(); release(); joinRuntimeWorker(t, uninstallDone, "publication cancellation") })
	waitRuntimeSignal(t, ctx, work.Done(), "installation cancellation")
	if _, err := os.Stat(installed); err != nil {
		t.Fatalf("uninstall did not wait for the publication owner: %v", err)
	}
	// An atomic publication already past its cancellation check may still finish.
	// Core must take the uninstall snapshot after this owner releases the files.
	published := filepath.Join(service.Root, "dev.lithe.test.managed-environment", "1.1.0")
	if err := os.MkdirAll(published, 0o700); err != nil {
		t.Fatal(err)
	}
	updated := bytes.Replace(manifest, []byte(`"version":"1.0.0"`), []byte(`"version":"1.1.0"`), 1)
	if err := os.WriteFile(filepath.Join(published, pluginpkg.ManifestFile), updated, 0o600); err != nil {
		t.Fatal(err)
	}
	release()
	waitRuntimeSignal(t, ctx, uninstallDone, "uninstall after publication ownership ended")
	if uninstallErr != nil {
		t.Fatal(uninstallErr)
	}
	if _, err := os.Stat(published); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("uninstall planned before the final publication and left its package: %v", err)
	}
}

func TestRuntimeCheckerCleanupFailureRemainsOwnedUntilRetry(t *testing.T) {
	manifest, _, packageRoot := runtimeFixture(t)
	home := runtimePayload(t)
	kernel := &runtimeResolverKernel{Client: core.NewClient(), queues: make(map[string]chan core.BackendEvent), external: map[string]string{"alpha": home, "beta": home}}
	var failStop atomic.Bool
	failStop.Store(true)
	stopFailure := errors.New("fixture native stop failed")
	kernel.stop = func(context.Context, string) error {
		if failStop.Load() {
			return stopFailure
		}
		return nil
	}
	kernel.destroy = kernel.stop
	kernel.waitError = func(string) error {
		if kernel.stops.Load() > 0 && failStop.Load() {
			return stopFailure
		}
		return nil
	}
	service, err := Open(kernel, store.At(t.TempDir()), t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	installed := installRuntimeFixture(t, service.Root, packageRoot, manifest)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	t.Cleanup(func() {
		failStop.Store(false)
		cleanupCtx, cleanupCancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cleanupCancel()
		if err := service.StopDisplaced(cleanupCtx, "dev.lithe.test.managed-environment", nil); err != nil {
			t.Errorf("cleanup retained checker: %v", err)
		}
	})
	if _, err := service.EnsureRuntimes(ctx, manifest, installed, "dev.lithe.test.managed-environment", "1.0.0", true, nil); !errors.Is(err, stopFailure) {
		t.Fatalf("lost native stop failure: %v", err)
	}
	if err := service.Uninstall(ctx, "dev.lithe.test.managed-environment", nil); !errors.Is(err, stopFailure) {
		t.Fatalf("uninstall ignored owned process failure: %v", err)
	}
	if _, err := os.Stat(installed); err != nil {
		t.Fatalf("failed stop removed the package: %v", err)
	}
	failStop.Store(false)
	if err := service.Uninstall(ctx, "dev.lithe.test.managed-environment", nil); err != nil {
		t.Fatalf("retry did not finish native cleanup: %v", err)
	}
	if _, err := os.Stat(installed); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("successful retry did not remove the package: %v", err)
	}
}

func TestDisposedRuntimeCheckerRecordsShutdownFailureWithoutRetainingOwnership(t *testing.T) {
	manifest, _, packageRoot := runtimeFixture(t)
	home := runtimePayload(t)
	kernel := &runtimeResolverKernel{Client: core.NewClient(), queues: make(map[string]chan core.BackendEvent), external: map[string]string{"alpha": home, "beta": home}}
	stopFailure := errors.New("fixture graceful shutdown failed")
	kernel.stop = func(context.Context, string) error { return stopFailure }
	service, err := Open(kernel, store.At(t.TempDir()), t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	installed := installRuntimeFixture(t, service.Root, packageRoot, manifest)
	var reported atomic.Int32
	service.RuntimeIssue = func(_ context.Context, err error) {
		if errors.Is(err, stopFailure) {
			reported.Add(1)
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if _, err := service.EnsureRuntimes(ctx, manifest, installed, "dev.lithe.test.managed-environment", "1.0.0", true, nil); err != nil {
		t.Fatalf("disposed checker retained ownership: %v", err)
	}
	if err := service.Uninstall(ctx, "dev.lithe.test.managed-environment", nil); err != nil {
		t.Fatalf("uninstall retried an already-destroyed session: %v", err)
	}
	if reported.Load() != 1 || kernel.stops.Load() != 1 {
		t.Fatalf("shutdown diagnostic=%d native stops=%d", reported.Load(), kernel.stops.Load())
	}
}

func TestRuntimeLanguageServerOwnershipSurvivesFailedDisposal(t *testing.T) {
	kernel := &runtimeResolverKernel{Client: core.NewClient(), queues: make(map[string]chan core.BackendEvent)}
	service, err := Open(kernel, store.At(t.TempDir()), t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	started, err := kernel.StartPluginLanguageServer(ctx, core.PluginBackendStart{})
	if err != nil {
		t.Fatal(err)
	}
	var failStop atomic.Bool
	failStop.Store(true)
	stopFailure := errors.New("fixture process still owns files")
	kernel.stop = func(context.Context, string) error {
		if failStop.Load() {
			return stopFailure
		}
		return nil
	}
	kernel.destroy = kernel.stop
	kernel.waitError = func(string) error {
		if failStop.Load() {
			return stopFailure
		}
		return nil
	}
	temporary := filepath.Join(t.TempDir(), "active-server")
	if err := os.MkdirAll(temporary, 0o700); err != nil {
		t.Fatal(err)
	}
	session := &LanguageSession{PluginID: "dev.lithe.test.managed-environment", LanguageID: "fixture", Session: pluginbackend.Session{ID: started.SessionID}, temporary: temporary}
	service.registerLanguageSession(session)
	t.Cleanup(func() {
		failStop.Store(false)
		cleanupCtx, cleanupCancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cleanupCancel()
		if err := service.StopDisplaced(cleanupCtx, session.PluginID, nil); err != nil {
			t.Errorf("retained language-server cleanup: %v", err)
		}
	})
	if err := service.StopLanguageServer(ctx, session); !errors.Is(err, stopFailure) {
		t.Fatalf("failed native stop=%v", err)
	}
	if _, err := os.Stat(temporary); err != nil {
		t.Fatalf("failed stop removed live process state: %v", err)
	}
	failStop.Store(false)
	if err := service.StopDisplaced(ctx, session.PluginID, nil); err != nil {
		t.Fatalf("plugin stop did not retry its retained language server: %v", err)
	}
	if _, err := os.Stat(temporary); !errors.Is(err, os.ErrNotExist) || kernel.stops.Load() != 2 {
		t.Fatalf("late cleanup state=%v stops=%d", err, kernel.stops.Load())
	}
}
