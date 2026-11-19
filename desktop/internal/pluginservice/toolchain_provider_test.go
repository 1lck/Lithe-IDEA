package pluginservice

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginpkg"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginstate"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/1lck/Lithe-IDEA/desktop/internal/toolchain"
)

const (
	toolchainFixturePlugin = "dev.lithe.test.toolchain"
	toolchainFixtureTool   = "dev.lithe.test.toolchain:tool"
	providerFixtureSource  = ".fixture-version"
)

const toolchainProviderFixtureManifest = `{
  "schemaVersion": 0,
  "id": "dev.lithe.test.toolchain",
  "displayName": "Toolchain fixture",
  "version": "1.0.0",
  "pluginAPIVersion": 0,
  "requires": {"backend": 0, "toolDefinitions": 0, "toolchainProviders": 0},
  "vendor": {"id": "dev.lithe.test", "displayName": "Test", "signatureRequirement": "publisherPackage"},
  "permissions": ["backend.launch", "toolchains.provide"],
  "backend": {
    "launch": {"kind": "packaged", "path": "provider.exe"},
    "arguments": ["-test.run=^TestToolchainProviderFixtureProcess$"]
  },
  "toolchainProviders": [{"id": "fixture", "displayName": "Fixture provider", "tools": ["dev.lithe.test.toolchain:tool"],
    "watchFiles": [{"reader": "native", "pattern": ".fixture-version"}]}],
  "toolDefinitions": [{
    "id": "dev.lithe.test.toolchain:tool",
    "displayName": "Fixture tool",
    "executableLayouts": [{"path": "bin/fixture"}],
    "executables": [
      {"id": "provider", "kind": "toolchain", "scope": "project"},
      {"id": "shell", "kind": "command", "command": "fixture-tool"},
      {"id": "installed", "kind": "toolchain", "scope": "installed"}
    ],
    "version": {"arguments": ["--version"], "pattern": "Fixture (\\d+(?:\\.\\d+)*)"},
    "commands": ["fixture-tool"],
    "launch": ["${executable}", "${arguments}"]
  }]
}`

type toolchainProviderFixtureConfig struct {
	Home string
}

func TestToolchainProviderFixtureProcess(t *testing.T) {
	data, err := os.ReadFile("toolchain-fixture.json")
	if errors.Is(err, os.ErrNotExist) {
		t.Skip("only the configured backend process serves the fixture")
	}
	var config toolchainProviderFixtureConfig
	if err != nil || json.Unmarshal(data, &config) != nil {
		os.Exit(2)
	}
	reader := bufio.NewReader(os.Stdin)
	count := 0
	for {
		var request struct {
			ID     json.RawMessage `json:"id"`
			Method string          `json:"method"`
			Params json.RawMessage `json:"params"`
		}
		if err := readToolchainFixtureFrame(reader, &request); err != nil {
			os.Exit(3)
		}
		if len(request.ID) == 0 {
			if request.Method == "exit" {
				os.Exit(0)
			}
			continue
		}
		var result any
		switch request.Method {
		case "initialize":
			var params struct {
				Capabilities struct {
					Experimental struct {
						Toolchains struct {
							Providers []string `json:"providers"`
						} `json:"litheToolchains"`
					} `json:"experimental"`
				} `json:"capabilities"`
			}
			if json.Unmarshal(request.Params, &params) != nil ||
				len(params.Capabilities.Experimental.Toolchains.Providers) != 1 ||
				params.Capabilities.Experimental.Toolchains.Providers[0] != "fixture" {
				os.Exit(4)
			}
			result = map[string]any{"capabilities": map[string]any{"experimental": map[string]any{
				"litheToolchains": map[string]any{"version": 0, "providers": []string{"fixture"}},
			}}}
		case "toolchains/query":
			var query core.ToolchainQueryParams
			if json.Unmarshal(request.Params, &query) != nil || query.ProviderID != "fixture" ||
				len(query.Tools) != 1 || query.Tools[0] != toolchainFixtureTool {
				os.Exit(5)
			}
			count++
			if err := os.WriteFile("query-count", []byte(strconv.Itoa(count)), 0o600); err != nil {
				os.Exit(6)
			}
			watch, statements := []string{}, []any{}
			if query.Workspace != nil {
				source := filepath.Join(query.Workspace.Root, providerFixtureSource)
				watch = append(watch, source)
				if data, err := os.ReadFile(source); err == nil {
					statements = append(statements, map[string]any{
						"tool": toolchainFixtureTool, "kind": "declaration", "scope": "project",
						"source": source, "request": string(data), "installation": config.Home, "reader": "native",
					})
				}
			}
			result = map[string]any{
				"operationID": query.OperationID, "generation": query.Generation, "providerID": query.ProviderID,
				"installations": []any{map[string]any{"tool": toolchainFixtureTool, "home": config.Home, "version": "7.1"}},
				"statements":    statements, "watch": watch,
			}
		case "shutdown":
		default:
			os.Exit(7)
		}
		body, err := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": request.ID, "result": result})
		if err != nil {
			os.Exit(8)
		}
		if _, err := fmt.Fprintf(os.Stdout, "Content-Length: %d\r\n\r\n%s", len(body), body); err != nil {
			os.Exit(9)
		}
	}
}

func readToolchainFixtureFrame(reader *bufio.Reader, request any) error {
	length := -1
	for {
		line, err := reader.ReadString('\n')
		if err != nil {
			return err
		}
		line = strings.TrimSpace(line)
		if line == "" {
			break
		}
		if key, value, ok := strings.Cut(line, ":"); ok && strings.EqualFold(key, "Content-Length") {
			length, err = strconv.Atoi(strings.TrimSpace(value))
			if err != nil {
				return err
			}
		}
	}
	if length < 0 || length > 1<<20 {
		return errors.New("invalid fixture frame length")
	}
	body := make([]byte, length)
	if _, err := io.ReadFull(reader, body); err != nil {
		return err
	}
	return json.Unmarshal(body, request)
}

func TestToolchainProviderQueriesThroughSharedBackendAndReobservesSources(t *testing.T) {
	client, preferences, plugins := core.NewClient(), store.At(t.TempDir()), t.TempDir()
	service, err := Open(client, preferences, plugins)
	if err != nil {
		t.Fatal(err)
	}
	service.Contexts.SetObserver(nil)
	t.Cleanup(func() { service.DetachWorkspaces()() })

	manifest := json.RawMessage(toolchainProviderFixtureManifest)
	installed := filepath.Join(plugins, toolchainFixturePlugin, "1.0.0")
	state := pluginpkg.VersionStateRoot(plugins, toolchainFixturePlugin, "1.0.0")
	home := t.TempDir()
	for _, directory := range []string{installed, state, filepath.Join(home, "bin")} {
		if err := os.MkdirAll(directory, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	write := func(path string, bytes []byte, mode os.FileMode) {
		t.Helper()
		if err := os.WriteFile(path, bytes, mode); err != nil {
			t.Fatal(err)
		}
	}
	binary, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	write(filepath.Join(installed, pluginpkg.ManifestFile), manifest, 0o600)
	// The fixture never changes its executable. A hard link lets the platform
	// reuse validation of the test binary instead of validating a second image.
	program := filepath.Join(installed, "provider.exe")
	if err := os.Link(binary, program); err != nil {
		image, readErr := os.ReadFile(binary)
		if readErr != nil {
			t.Fatal(readErr)
		}
		write(program, image, 0o700)
	}
	write(filepath.Join(home, "bin", "fixture"), nil, 0o700)
	config, err := json.Marshal(toolchainProviderFixtureConfig{Home: home})
	if err != nil {
		t.Fatal(err)
	}
	write(filepath.Join(state, "toolchain-fixture.json"), config, 0o600)
	if err := pluginstate.New(preferences).SetEnabled(toolchainFixturePlugin, true); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	workspace := t.TempDir()
	service.Contexts.Open(workspace)
	options := service.ToolchainOptions(workspace, toolchain.Options{
		Home: t.TempDir(), Platform: toolchain.PlatformName(runtime.GOOS), Environment: map[string]string{},
		Probe:  func(context.Context, string, []string) (string, int, error) { return "Fixture 7.1", 0, nil },
		Lookup: func(string) (string, error) { return "", os.ErrNotExist },
	})
	if service.Host.Running(toolchainFixturePlugin) != nil {
		t.Fatal("opening a workspace started a provider before discovery was needed")
	}
	load := func(layer string, counts ...int) {
		t.Helper()
		snapshot, err := toolchain.Load(ctx, client, workspace, ".", []json.RawMessage{manifest}, options)
		if err != nil {
			var rejection *core.MarketplaceRejection
			if errors.As(err, &rejection) {
				t.Fatalf("%s: %v", rejection.Field, err)
			}
			t.Fatal(err)
		}
		if len(snapshot.Tools) != 1 || snapshot.Tools[0].Effective == nil || snapshot.Tools[0].Effective.Layer != layer ||
			snapshot.Tools[0].Effective.Provider != toolchainFixturePlugin+":fixture" || len(snapshot.Tools[0].Installations) != 1 {
			t.Fatalf("toolchain selection = %+v, want %s resolution and a provider installation", snapshot.Tools, layer)
		}
		got, err := os.ReadFile(filepath.Join(state, "query-count"))
		count, parseErr := strconv.Atoi(string(got))
		if err != nil || parseErr != nil || !slices.Contains(counts, count) {
			t.Fatalf("provider ran %q queries, want one of %v (read: %v, parse: %v)", got, counts, err, parseErr)
		}
	}
	load("automatic", 1)
	backend := service.Host.Running(toolchainFixturePlugin)
	if backend == nil {
		t.Fatal("provider ran outside the shared plugin backend")
	}
	load("automatic", 1)
	write(filepath.Join(workspace, providerFixtureSource), []byte("7.1"), 0o600)
	// The native watcher can deliver the create event during registration of
	// the refreshed generation. A retry is allowed once, under the same deadline.
	load("project", 2, 3)
	global := service.ToolchainOptions("", toolchain.Options{
		Global: true, Home: options.Home, Environment: options.Environment, Probe: options.Probe, Lookup: options.Lookup,
	})
	selection, err := toolchain.Resolve(ctx, client, "", ".", toolchainFixtureTool, "", nil, []json.RawMessage{manifest}, global)
	if err != nil || selection.Layer != "automatic" || selection.Provider != toolchainFixturePlugin+":fixture" {
		t.Fatalf("global selection = %+v, %v", selection, err)
	}
	if service.Host.Running(toolchainFixturePlugin) != backend {
		t.Fatal("an observation change started a second copy of the plugin backend")
	}
	stop := service.DetachWorkspaces()
	stop()
	if service.Host.Running(toolchainFixturePlugin) != nil {
		t.Fatal("closing the project left a provider backend registered")
	}
	if _, err := toolchain.Load(ctx, client, workspace, ".", []json.RawMessage{manifest}, options); !errors.Is(err, ErrContextExpired) {
		t.Fatalf("closed workspace query error = %v, want context expiration", err)
	}
}

func TestToolchainProviderQueriesTheInstalledVersionAfterUpgrade(t *testing.T) {
	client, preferences, plugins := core.NewClient(), store.At(t.TempDir()), t.TempDir()
	service, err := Open(client, preferences, plugins)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { service.DetachWorkspaces()() })
	if err := pluginstate.New(preferences).SetEnabled(toolchainFixturePlugin, true); err != nil {
		t.Fatal(err)
	}
	binary, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	install := func(version string) string {
		t.Helper()
		packageDir := filepath.Join(plugins, toolchainFixturePlugin, version)
		stateDir := pluginpkg.VersionStateRoot(plugins, toolchainFixturePlugin, version)
		home := t.TempDir()
		for _, path := range []string{packageDir, stateDir, filepath.Join(home, "bin")} {
			if err := os.MkdirAll(path, 0o700); err != nil {
				t.Fatal(err)
			}
		}
		program := filepath.Join(packageDir, "provider.exe")
		if err := os.Link(binary, program); err != nil {
			image, readErr := os.ReadFile(binary)
			if readErr != nil {
				t.Fatal(readErr)
			}
			if err := os.WriteFile(program, image, 0o700); err != nil {
				t.Fatal(err)
			}
		}
		config, err := json.Marshal(toolchainProviderFixtureConfig{Home: home})
		if err != nil {
			t.Fatal(err)
		}
		manifest := strings.Replace(toolchainProviderFixtureManifest, `"version": "1.0.0"`, `"version": "`+version+`"`, 1)
		executable := filepath.Join(home, "bin", "fixture")
		for path, data := range map[string][]byte{
			filepath.Join(packageDir, pluginpkg.ManifestFile): []byte(manifest),
			filepath.Join(stateDir, "toolchain-fixture.json"): config,
			executable: nil,
		} {
			if err := os.WriteFile(path, data, 0o700); err != nil {
				t.Fatal(err)
			}
		}
		canonical, err := filepath.EvalSymlinks(executable)
		if err != nil {
			t.Fatal(err)
		}
		return canonical
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	options := service.ToolchainOptions("", toolchain.Options{
		Global: true, Home: t.TempDir(), Environment: map[string]string{},
		Probe:  func(context.Context, string, []string) (string, int, error) { return "Fixture 7.1", 0, nil },
		Lookup: func(string) (string, error) { return "", os.ErrNotExist },
	})
	resolve := func(version, executable string) *BackendSession {
		t.Helper()
		entries, err := service.Manager.Installed()
		if err != nil {
			t.Fatal(err)
		}
		selected, err := service.ToolchainPlugins(ctx, entries)
		if err != nil || len(selected) != 1 || selected[0].Version != version {
			t.Fatalf("current toolchain manifest = %+v, error = %v, want %s", selected, err, version)
		}
		selection, err := toolchain.Resolve(ctx, client, "", ".", toolchainFixtureTool, "", nil, []json.RawMessage{selected[0].Manifest}, options)
		session := service.Host.Running(toolchainFixturePlugin)
		if err != nil || filepath.FromSlash(selection.Executable) != executable {
			t.Fatalf("installed %s, executable %q, want %q (error %v)", version, selection.Executable, executable, err)
		}
		if session == nil || session.Version != version {
			t.Fatalf("the backend for installed version %s did not own the query", version)
		}
		return session
	}
	old := resolve("1.0.0", install("1.0.0"))
	current := resolve("1.1.0", install("1.1.0"))
	if current == old {
		t.Fatal("the upgrade reused the old backend")
	}
	select {
	case <-old.done:
	default:
		t.Fatal("the replacement published before the old backend stopped")
	}
	if _, err := service.Host.ensureBackend(ctx, toolchainFixturePlugin, old.Version); !errors.Is(err, ErrBackendUnavailable) {
		t.Fatalf("a late query for the superseded version returned %v", err)
	}
	if service.Host.Running(toolchainFixturePlugin) != current {
		t.Fatal("a late query displaced the current backend")
	}
}

type toolchainCancellationKernel struct {
	*core.Client
	submitted chan string
	cancelled chan string
}

func (k *toolchainCancellationKernel) RequestPluginToolchain(ctx context.Context, _ string, params core.ToolchainQueryParams, _ int) error {
	select {
	case k.submitted <- params.OperationID:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func (k *toolchainCancellationKernel) CancelPluginOperation(ctx context.Context, _, operation string) error {
	select {
	case k.cancelled <- operation:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func TestToolchainProviderCancellationDoesNotCompleteTheNextQuery(t *testing.T) {
	kernel := &toolchainCancellationKernel{
		Client: core.NewClient(), submitted: make(chan string, 2), cancelled: make(chan string, 1),
	}
	service, err := Open(kernel, store.At(t.TempDir()), t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	session := &BackendSession{
		host: service.Host, ready: true, waiters: make(map[string]chan core.BackendEvent), changed: make(chan struct{}),
	}
	type outcome struct {
		reply core.ToolchainProviderReply
		err   error
	}
	ctx, finish := context.WithTimeout(context.Background(), 5*time.Second)
	defer finish()
	query := func(queryCtx context.Context, id string) <-chan outcome {
		done := make(chan outcome, 1)
		go func() {
			reply, err := session.queryToolchain(queryCtx, core.ToolchainQueryParams{OperationID: id})
			done <- outcome{reply, err}
		}()
		return done
	}
	await := func(events <-chan string, want string) {
		t.Helper()
		select {
		case got := <-events:
			if got != want {
				t.Fatalf("observed operation %q, want %q", got, want)
			}
		case <-ctx.Done():
			t.Fatalf("operation %q was not observed: %v", want, ctx.Err())
		}
	}
	complete := func(id, wire string) {
		data := json.RawMessage(fmt.Sprintf(`{"value":{"id":%q,"response":{}}}`, wire))
		session.observe(core.BackendEvent{Type: "requestCompleted", OperationID: id, Result: data})
	}
	cancellable, cancel := context.WithCancel(ctx)
	defer cancel()
	first := query(cancellable, "first")
	await(kernel.submitted, "first")
	cancel()
	await(kernel.cancelled, "first")
	select {
	case got := <-first:
		if !errors.Is(got.err, context.Canceled) {
			t.Fatalf("cancelled query outcome = %+v", got)
		}
	case <-ctx.Done():
		t.Fatal("cancelled query did not return")
	}
	next := query(ctx, "second")
	await(kernel.submitted, "second")
	complete("first", "expired")
	complete("second", "current")
	select {
	case got := <-next:
		if got.err != nil || string(got.reply.ID) != `"current"` {
			t.Fatalf("second query = %+v, want the current wire reply", got)
		}
	case <-ctx.Done():
		t.Fatal("second query did not return")
	}
}
