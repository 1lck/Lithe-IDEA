package buildprovider

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginbackend"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginhost"
)

const buildProviderHelperEnv = "LITHE_TEST_BUILD_PROVIDER"

// TestBuildProviderHelper is the provider process. It speaks only the framed
// JSON-RPC subset Core negotiates and never enters a product path.
func TestBuildProviderHelper(t *testing.T) {
	if os.Getenv(buildProviderHelperEnv) != "1" {
		return
	}
	reader := bufio.NewReader(os.Stdin)
	write := func(value any) {
		body, err := json.Marshal(value)
		if err != nil {
			os.Exit(2)
		}
		if _, err := fmt.Fprintf(os.Stdout, "Content-Length: %d\r\n\r\n%s", len(body), body); err != nil {
			os.Exit(3)
		}
	}
	reply := func(id json.RawMessage, result any) {
		write(map[string]any{"jsonrpc": "2.0", "id": id, "result": result})
	}
	notify := func(method string, params any) {
		write(map[string]any{"jsonrpc": "2.0", "method": method, "params": params})
	}
	for {
		length := -1
		for {
			line, err := reader.ReadString('\n')
			if err != nil {
				os.Exit(0)
			}
			line = strings.TrimSpace(line)
			if line == "" {
				break
			}
			if key, value, ok := strings.Cut(line, ":"); ok && strings.EqualFold(key, "Content-Length") {
				length, err = strconv.Atoi(strings.TrimSpace(value))
				if err != nil {
					os.Exit(4)
				}
			}
		}
		if length < 0 || length > 1<<20 {
			os.Exit(5)
		}
		body := make([]byte, length)
		if _, err := io.ReadFull(reader, body); err != nil {
			os.Exit(6)
		}
		var request struct {
			ID     json.RawMessage `json:"id"`
			Method string          `json:"method"`
			Params json.RawMessage `json:"params"`
		}
		if err := json.Unmarshal(body, &request); err != nil {
			os.Exit(7)
		}
		if len(request.ID) == 0 {
			continue
		}
		switch request.Method {
		case "initialize":
			reply(request.ID, map[string]any{
				"capabilities": map[string]any{
					"experimental": map[string]any{"litheBuild": map[string]any{"version": 0}},
				},
			})
		case "lithe/build/model":
			reply(request.ID, map[string]any{
				"format":   "litheBuildModel",
				"version":  0,
				"projects": []any{map[string]any{"path": ".", "name": "fixture"}},
			})
		case "lithe/build/execute":
			var params struct {
				Task string `json:"task"`
			}
			_ = json.Unmarshal(request.Params, &params)
			if params.Task == "slow" {
				continue
			}
			notify("lithe/build/progress", map[string]any{
				"operationID": json.RawMessage(request.ID),
				"message":     "building",
				"output":      "compiling\n",
			})
			reply(request.ID, map[string]any{"exitCode": 0, "output": "built\n"})
		case "shutdown":
			reply(request.ID, nil)
		case "exit":
			os.Exit(0)
		default:
			reply(request.ID, nil)
		}
	}
}

func TestProviderModelTaskAndCancellation(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("the fixture copies the test executable with POSIX framing and paths")
	}
	client, ctx := core.NewClient(), testContext(t)
	workspace := t.TempDir()
	if err := os.WriteFile(filepath.Join(workspace, "fixture.marker"), []byte("marker\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	packageDirectory := t.TempDir()
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	source, err := os.Open(executable)
	if err != nil {
		t.Fatal(err)
	}
	target, err := os.OpenFile(filepath.Join(packageDirectory, "provider"), os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o755)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := io.Copy(target, source); err != nil {
		t.Fatal(err)
	}
	_ = source.Close()
	if err := target.Close(); err != nil {
		t.Fatal(err)
	}
	manifest := json.RawMessage(fmt.Sprintf(`{
		"schemaVersion": 0,
		"id": "dev.lithe.fixture.build-provider-test",
		"displayName": "Build Provider Test",
		"version": "1.0.0",
		"pluginAPIVersion": 0,
		"requires": {"buildProviders": 0, "buildSystems": 0},
		"vendor": {"id": "org.example", "displayName": "Example", "signatureRequirement": "publisherPackage"},
		"permissions": ["languageServer.launch", "process.build"],
		"activationEvents": ["onBuildSystem:fixture"],
		"languages": [],
		"buildSystems": [{
			"id": "fixture",
			"displayName": "Fixture",
			"detection": {"markers": ["fixture.marker"], "nesting": "outermost"},
			"invocation": {"executables": [{"kind": "command", "command": "fixture-tool"}]},
			"provider": {
				"launch": {"kind": "packaged", "path": "provider"},
				"arguments": ["-test.run=^TestBuildProviderHelper$"],
				"executesProjectCode": false,
				"mayUseNetwork": false
			},
			"model": {"source": "provider"},
			"tasks": [{
				"id": "build",
				"displayName": "Build",
				"group": "build",
				"scopes": ["workspace"],
				"source": "provider",
				"arguments": []
			}, {
				"id": "slow",
				"displayName": "Slow",
				"group": "build",
				"scopes": ["workspace"],
				"source": "provider",
				"arguments": []
			}]
		}]
	}`))
	validated, err := client.ValidatePluginManifest(ctx, manifest, pluginhost.Declared().Clone())
	if err != nil {
		t.Fatal(err)
	}
	detection, err := client.DetectBuildSystems(ctx, workspace, []json.RawMessage{validated})
	if err != nil {
		t.Fatal(err)
	}
	if len(detection.Instances) != 1 {
		t.Fatalf("instances = %+v", detection.Instances)
	}
	if err := os.MkdirAll(filepath.Join(packageDirectory, "state"), 0o700); err != nil {
		t.Fatal(err)
	}
	runner := pluginbackend.New(client, pluginhost.NewServices())
	rootURI := (&url.URL{Scheme: "file", Path: workspace}).String()
	provider, err := Start(ctx, runner, pluginbackend.StartRequest{
		Manifest:         validated,
		PackageDirectory: packageDirectory,
		PluginID:         "dev.lithe.fixture.build-provider-test",
		ProviderID:       "dev.lithe.fixture.build-provider-test/fixture",
		BuildSystemID:    "fixture",
		StateDirectory:   filepath.Join(packageDirectory, "state"),
		Architecture:     core.PluginArchitecture(),
		RootURI:          rootURI,
		WorkingDirectory: workspace,
		Environment:      map[string]string{buildProviderHelperEnv: "1"},
		// The fixture is this whole (possibly race-instrumented) test binary.
		// Under a loaded machine its startup can exceed Core's 10s default.
		InitializeTimeoutMilliseconds: 60_000,
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		cleanup, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := provider.Close(cleanup); err != nil {
			t.Errorf("close provider: %v", err)
		}
	})

	modelPlan, err := client.PlanBuildModel(ctx, validated, "fixture", core.BuildPlanRequest{Root: ".", WorkspaceRoot: workspace})
	if err != nil {
		t.Fatal(err)
	}
	if modelPlan.Provider == nil || modelPlan.Provider.Method != "lithe/build/model" {
		t.Fatalf("model plan = %+v", modelPlan)
	}
	modelOperation, err := provider.Execute(ctx, modelPlan.Provider.Method, modelPlan.Provider.Params, 30_000)
	if err != nil {
		t.Fatal(err)
	}
	modelResult, err := modelOperation.Wait(ctx)
	if err != nil {
		t.Fatal(err)
	}
	model, err := client.DecodeBuildModel(ctx, validated, "fixture", core.BuildDecodeModelRequest{
		WorkspaceRoot: workspace,
		Root:          ".",
		Result:        modelResult,
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(model.Projects) != 1 || model.Projects[0].Name != "fixture" {
		t.Fatalf("model = %+v", model)
	}

	taskPlan, err := client.PlanBuildTask(ctx, validated, "fixture", core.BuildPlanRequest{Root: ".", WorkspaceRoot: workspace, Task: "build"})
	if err != nil {
		t.Fatal(err)
	}
	if taskPlan.Provider == nil || taskPlan.Provider.Method != "lithe/build/execute" {
		t.Fatalf("task plan = %+v", taskPlan)
	}
	taskOperation, err := provider.Execute(ctx, taskPlan.Provider.Method, taskPlan.Provider.Params, 30_000)
	if err != nil {
		t.Fatal(err)
	}
	var progress []Progress
	for event := range taskOperation.Progress() {
		progress = append(progress, event)
	}
	if len(progress) == 0 || progress[0].Message != "building" || progress[0].Output != "compiling\n" {
		t.Fatalf("progress = %+v", progress)
	}
	taskResult, err := taskOperation.Wait(ctx)
	if err != nil {
		t.Fatal(err)
	}
	var execution struct {
		ExitCode int    `json:"exitCode"`
		Output   string `json:"output"`
	}
	if err := json.Unmarshal(taskResult, &execution); err != nil {
		t.Fatal(err)
	}
	if execution.ExitCode != 0 || execution.Output != "built\n" {
		t.Fatalf("execution = %+v", execution)
	}

	slowPlan, err := client.PlanBuildTask(ctx, validated, "fixture", core.BuildPlanRequest{Root: ".", WorkspaceRoot: workspace, Task: "slow"})
	if err != nil {
		t.Fatal(err)
	}
	slow, err := provider.Execute(ctx, slowPlan.Provider.Method, slowPlan.Provider.Params, 30_000)
	if err != nil {
		t.Fatal(err)
	}
	if err := provider.Cancel(ctx, slow); err != nil {
		t.Fatal(err)
	}
	wait, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	if _, err := slow.Wait(wait); err == nil {
		t.Fatal("a cancelled slow task completed successfully")
	}
}

func testContext(t *testing.T) context.Context {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	t.Cleanup(cancel)
	return ctx
}
