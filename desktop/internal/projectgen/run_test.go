package projectgen

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// testDeadline bounds every wait of this file, so a stuck run fails here and not in CI.
const testDeadline = 20 * time.Second

// TestMain doubles as the scaffolding tool the command steps run: the test
// binary re-executes itself with LITHE_PROJECTGEN_HELPER set.
func TestMain(m *testing.M) {
	if mode := os.Getenv("LITHE_PROJECTGEN_HELPER"); mode != "" {
		os.Exit(helper(mode))
	}
	os.Exit(m.Run())
}

func helper(mode string) int {
	switch mode {
	case "scaffold":
		// Like Maven's archetype: the project is written into a subdirectory.
		_ = os.MkdirAll(filepath.Join("demo", "src"), 0o755)
		_ = os.WriteFile(filepath.Join("demo", "pom.xml"), []byte("<project/>"), 0o644)
		_ = os.WriteFile(filepath.Join("demo", "src", "Main.txt"), []byte(os.Getenv("LITHE_FLAG")), 0o644)
		fmt.Println("scaffolded demo")
		return 0
	case "fail":
		fmt.Println("about to fail")
		fmt.Fprintln(os.Stderr, "boom")
		return 3
	case "block":
		fmt.Println("ready")
		time.Sleep(testDeadline * 2)
		return 0
	}
	return 9
}

func helperCommand(mode string, extra map[string]string) Resolver {
	return func(context.Context, string) (Command, error) {
		executable, err := os.Executable()
		if err != nil {
			return Command{}, err
		}
		environment := map[string]string{"LITHE_PROJECTGEN_HELPER": mode}
		for name, value := range extra {
			environment[name] = value
		}
		return Command{Executable: executable, Environment: environment}, nil
	}
}

type fakeKernel struct {
	mu         sync.Mutex
	gitRoots   []string
	gitErr     error
	extracted  []string
	extractErr error
}

func (k *fakeKernel) InitializeGit(_ context.Context, root string) error {
	k.mu.Lock()
	defer k.mu.Unlock()
	k.gitRoots = append(k.gitRoots, root)
	return k.gitErr
}

func (k *fakeKernel) ExtractProjectArchive(_ context.Context, archive, destination string) (int, error) {
	k.mu.Lock()
	defer k.mu.Unlock()
	k.extracted = append(k.extracted, destination)
	if k.extractErr != nil {
		return 0, k.extractErr
	}
	data, err := os.ReadFile(archive)
	if err != nil {
		return 0, err
	}
	return 1, os.WriteFile(filepath.Join(destination, "from-archive.txt"), data, 0o644)
}

func files(entries ...core.ProjectPlanFile) core.ProjectPlanStep {
	return core.ProjectPlanStep{Kind: "writeFiles", Files: entries}
}

func entries(t *testing.T, directory string) []string {
	t.Helper()
	found, err := os.ReadDir(directory)
	if err != nil {
		t.Fatal(err)
	}
	names := make([]string, 0, len(found))
	for _, entry := range found {
		names = append(names, entry.Name())
	}
	return names
}

func newRequest(t *testing.T, steps ...core.ProjectPlanStep) (Request, string) {
	t.Helper()
	parent := t.TempDir()
	return Request{
		Parent: parent, Name: "demo",
		Plan:   core.ProjectGenerationPlan{ProjectName: "demo", Steps: steps},
		Kernel: &fakeKernel{},
	}, parent
}

func TestRunWritesTemplateFilesAtomicallyAndOpensExistingFiles(t *testing.T) {
	request, parent := newRequest(t, files(
		core.ProjectPlanFile{Path: "pom.xml", Contents: "<project/>"},
		core.ProjectPlanFile{Path: "src/main/Main.java", Contents: "class Main {}"},
		core.ProjectPlanFile{Path: "run.sh", Contents: "#!/bin/sh\n", Executable: true},
	))
	request.Plan.OpenFiles = []string{"pom.xml", "missing.txt"}
	var steps []Event
	request.Observe = func(event Event) {
		if event.Kind == EventStep {
			steps = append(steps, event)
		}
	}
	result := Run(t.Context(), request)
	if result.Failure != nil {
		t.Fatal(result.Failure)
	}
	if result.Path != filepath.Join(parent, "demo") || len(result.OpenFiles) != 1 || result.OpenFiles[0] != "pom.xml" {
		t.Fatalf("result = %+v", result)
	}
	data, err := os.ReadFile(filepath.Join(result.Path, "src", "main", "Main.java"))
	if err != nil || string(data) != "class Main {}" {
		t.Fatalf("Main.java = %q, %v", data, err)
	}
	if runtime.GOOS != "windows" {
		if info, err := os.Stat(filepath.Join(result.Path, "run.sh")); err != nil || info.Mode().Perm()&0o100 == 0 {
			t.Fatalf("run.sh is not executable: %v %v", info, err)
		}
	}
	if names := entries(t, parent); len(names) != 1 || names[0] != "demo" {
		t.Fatalf("the parent holds %v, want only the project (no staging directory)", names)
	}
	if names := entries(t, result.Path); strings.Contains(strings.Join(names, ","), ".lithe-write") {
		t.Fatalf("a temporary write file was left: %v", names)
	}
	if len(steps) != 1 || steps[0].Step != 1 || steps[0].Steps != 1 {
		t.Fatalf("step events = %+v", steps)
	}
}

func TestRunRefusesAnExistingDestinationWithoutTouchingIt(t *testing.T) {
	request, parent := newRequest(t, files(core.ProjectPlanFile{Path: "a.txt", Contents: "new"}))
	existing := filepath.Join(parent, "demo")
	if err := os.Mkdir(existing, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(existing, "keep.txt"), []byte("mine"), 0o644); err != nil {
		t.Fatal(err)
	}
	result := Run(t.Context(), request)
	if result.Failure == nil || result.Failure.Reason != ReasonExists || result.Path != "" {
		t.Fatalf("result = %+v", result)
	}
	if data, _ := os.ReadFile(filepath.Join(existing, "keep.txt")); string(data) != "mine" {
		t.Fatalf("the existing directory was changed: %q", data)
	}
	if names := entries(t, parent); len(names) != 1 {
		t.Fatalf("the parent holds %v", names)
	}
}

func TestRunRefusesPathsThatLeaveTheProject(t *testing.T) {
	for _, path := range []string{"../outside.txt", "a/../../outside.txt", "/etc/passwd", `a\b.txt`, "", "a//b"} {
		request, parent := newRequest(t, files(core.ProjectPlanFile{Path: path, Contents: "x"}))
		result := Run(t.Context(), request)
		if result.Failure == nil || result.Failure.Reason != ReasonStepFailed {
			t.Fatalf("path %q: result = %+v", path, result)
		}
		if names := entries(t, parent); len(names) != 0 {
			t.Fatalf("path %q left %v", path, names)
		}
	}
}

func TestWriteFileRefusesSymbolicLinkEscapes(t *testing.T) {
	root := t.TempDir()
	outside := t.TempDir()
	if err := os.Symlink(outside, filepath.Join(root, "link")); err != nil {
		t.Skipf("symbolic links are not available: %v", err)
	}
	if err := writeFile(root, "link/escape.txt", "x", false); !errors.Is(err, errEscape) {
		t.Fatalf("write through a linked directory: %v", err)
	}
	if err := os.WriteFile(filepath.Join(outside, "target.txt"), []byte("original"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(outside, "target.txt"), filepath.Join(root, "file-link")); err != nil {
		t.Fatal(err)
	}
	if err := writeFile(root, "file-link", "x", false); !errors.Is(err, errEscape) {
		t.Fatalf("write onto a linked file: %v", err)
	}
	if names := entries(t, outside); len(names) != 1 {
		t.Fatalf("the outside directory changed: %v", names)
	}
	if data, _ := os.ReadFile(filepath.Join(outside, "target.txt")); string(data) != "original" {
		t.Fatalf("the link target was overwritten: %q", data)
	}
}

func TestRunCommandCollectsTheScaffoldedSubdirectory(t *testing.T) {
	collect := "demo"
	request, _ := newRequest(t, core.ProjectPlanStep{
		Kind: "command", Command: "scaffold", Collect: &collect,
		Environment: map[string]string{"LITHE_FLAG": "from-plan"},
	})
	request.Resolve = helperCommand("scaffold", nil)
	var output []string
	var mu sync.Mutex
	request.Observe = func(event Event) {
		if event.Kind == EventOutput {
			mu.Lock()
			output = append(output, event.Text)
			mu.Unlock()
		}
	}
	result := Run(t.Context(), request)
	if result.Failure != nil {
		t.Fatal(result.Failure, result.Failure.Tail)
	}
	if data, err := os.ReadFile(filepath.Join(result.Path, "pom.xml")); err != nil || string(data) != "<project/>" {
		t.Fatalf("pom.xml = %q, %v", data, err)
	}
	if data, _ := os.ReadFile(filepath.Join(result.Path, "src", "Main.txt")); string(data) != "from-plan" {
		t.Fatalf("the plan's environment did not reach the tool: %q", data)
	}
	if _, err := os.Stat(filepath.Join(result.Path, "demo")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("the collected directory is still there: %v", err)
	}
	mu.Lock()
	defer mu.Unlock()
	if len(output) != 1 || output[0] != "scaffolded demo" {
		t.Fatalf("output lines = %v", output)
	}
}

func TestRunFailedCommandReportsItsOutputAndLeavesNothing(t *testing.T) {
	request, parent := newRequest(t,
		files(core.ProjectPlanFile{Path: "a.txt", Contents: "x"}),
		core.ProjectPlanStep{Kind: "command", Command: "fail"})
	request.Resolve = helperCommand("fail", nil)
	result := Run(t.Context(), request)
	if result.Failure == nil || result.Failure.Reason != ReasonCommandFailed {
		t.Fatalf("result = %+v", result)
	}
	if !strings.Contains(result.Failure.Tail, "about to fail") || !strings.Contains(result.Failure.Tail, "boom") {
		t.Fatalf("tail = %q", result.Failure.Tail)
	}
	if result.Path != "" || len(entries(t, parent)) != 0 {
		t.Fatalf("a failed generation left %v (path %q)", entries(t, parent), result.Path)
	}
}

func TestRunMissingCommandIsReported(t *testing.T) {
	request, parent := newRequest(t, core.ProjectPlanStep{Kind: "command", Command: "no-such-tool"})
	request.Resolve = func(context.Context, string) (Command, error) {
		return Command{}, fmt.Errorf("%w: no-such-tool", ErrCommandMissing)
	}
	result := Run(t.Context(), request)
	if result.Failure == nil || result.Failure.Reason != ReasonCommandMissing || len(entries(t, parent)) != 0 {
		t.Fatalf("result = %+v, parent %v", result, entries(t, parent))
	}
}

func TestRunCancelStopsTheCommandAndRemovesStaging(t *testing.T) {
	request, parent := newRequest(t, core.ProjectPlanStep{Kind: "command", Command: "block", TimeoutSeconds: 60})
	request.Resolve = helperCommand("block", nil)
	ctx, cancel := context.WithTimeout(t.Context(), testDeadline)
	defer cancel()
	ready := make(chan struct{})
	var once sync.Once
	request.Observe = func(event Event) {
		if event.Kind == EventOutput && event.Text == "ready" {
			once.Do(func() { close(ready) })
		}
	}
	done := make(chan Result, 1)
	go func() { done <- Run(ctx, request) }()
	select {
	case <-ready:
	case <-ctx.Done():
		t.Fatal("the command never reported ready")
	}
	cancel()
	select {
	case result := <-done:
		if result.Failure == nil || result.Failure.Reason != ReasonCancelled || !errors.Is(result.Failure, context.Canceled) {
			t.Fatalf("result = %+v", result)
		}
		if result.Path != "" || len(entries(t, parent)) != 0 {
			t.Fatalf("cancel left %v", entries(t, parent))
		}
	case <-time.After(testDeadline):
		t.Fatal("cancel did not stop the run")
	}
}

func TestRunCommandTimeoutIsDistinctFromCancel(t *testing.T) {
	request, parent := newRequest(t, core.ProjectPlanStep{Kind: "command", Command: "block", TimeoutSeconds: 1})
	request.Resolve = helperCommand("block", nil)
	result := Run(t.Context(), request)
	if result.Failure == nil || result.Failure.Reason != ReasonTimedOut {
		t.Fatalf("result = %+v", result)
	}
	if len(entries(t, parent)) != 0 {
		t.Fatalf("a timeout left %v", entries(t, parent))
	}
}

func TestRunKeepsTheProjectWhenGitFails(t *testing.T) {
	request, parent := newRequest(t, files(core.ProjectPlanFile{Path: "a.txt", Contents: "x"}))
	kernel := &fakeKernel{gitErr: errors.New("git is not installed")}
	request.Kernel, request.Git = kernel, true
	result := Run(t.Context(), request)
	if result.Failure == nil || result.Failure.Reason != ReasonGitFailed {
		t.Fatalf("result = %+v", result)
	}
	if result.Path != filepath.Join(parent, "demo") {
		t.Fatalf("the created directory was not reported: %q", result.Path)
	}
	if _, err := os.Stat(filepath.Join(result.Path, "a.txt")); err != nil {
		t.Fatalf("the project was not kept: %v", err)
	}
	if len(kernel.gitRoots) != 1 || kernel.gitRoots[0] != result.Path {
		t.Fatalf("git roots = %v", kernel.gitRoots)
	}
}

func TestRunKeepsTheProjectWhenSavingPinsFails(t *testing.T) {
	request, _ := newRequest(t, files(core.ProjectPlanFile{Path: "a.txt", Contents: "x"}))
	request.Plan.ToolPins = []core.ProjectPlanToolPin{{Field: "sdk", Tool: "python", PinAs: "project", Home: "/opt/py"}}
	var savedRoot string
	request.SavePins = func(_ context.Context, root string, plan core.ProjectGenerationPlan) error {
		savedRoot = root
		return errors.New("the pin file is read-only")
	}
	result := Run(t.Context(), request)
	if result.Failure == nil || result.Failure.Reason != ReasonPinFailed || result.Path == "" || savedRoot != result.Path {
		t.Fatalf("result = %+v, pins saved in %q", result, savedRoot)
	}
}

func TestRunArchiveDownloadsThenHandsTheZipToCore(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("zip-bytes"))
	}))
	defer server.Close()
	request, _ := newRequest(t, core.ProjectPlanStep{Kind: "archive", URL: server.URL + "/starter.zip", Format: "zip"})
	kernel := &fakeKernel{}
	request.Kernel = kernel
	result := Run(t.Context(), request)
	if result.Failure != nil {
		t.Fatal(result.Failure)
	}
	if data, _ := os.ReadFile(filepath.Join(result.Path, "from-archive.txt")); string(data) != "zip-bytes" {
		t.Fatalf("the archive was not extracted into the project: %q", data)
	}
	if len(kernel.extracted) != 1 || strings.HasSuffix(kernel.extracted[0], "demo") {
		t.Fatalf("extraction ran into %v, want the staging directory", kernel.extracted)
	}
}

func TestRunArchiveFailuresLeaveNothing(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, "no", http.StatusBadGateway)
	}))
	defer server.Close()
	request, parent := newRequest(t, core.ProjectPlanStep{Kind: "archive", URL: server.URL})
	result := Run(t.Context(), request)
	if result.Failure == nil || result.Failure.Reason != ReasonDownloadFailed || len(entries(t, parent)) != 0 {
		t.Fatalf("result = %+v, parent %v", result, entries(t, parent))
	}
	request, parent = newRequest(t, core.ProjectPlanStep{Kind: "archive", URL: "http://example.com/starter.zip"})
	result = Run(t.Context(), request)
	if result.Failure == nil || !errors.Is(result.Failure, errInsecureURL) || len(entries(t, parent)) != 0 {
		t.Fatalf("a plain-HTTP remote archive was not refused: %+v", result)
	}
	ok := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { _, _ = w.Write([]byte("x")) }))
	defer ok.Close()
	request, parent = newRequest(t, core.ProjectPlanStep{Kind: "archive", URL: ok.URL})
	request.Kernel = &fakeKernel{extractErr: &core.ProjectRejection{Code: "plugin.project.archiveInvalid", Message: "bad"}}
	result = Run(t.Context(), request)
	if result.Failure == nil || result.Failure.Reason != ReasonArchiveInvalid || len(entries(t, parent)) != 0 {
		t.Fatalf("result = %+v, parent %v", result, entries(t, parent))
	}
}

func TestRunRejectsRelativeParent(t *testing.T) {
	request, _ := newRequest(t)
	request.Parent = "relative"
	if result := Run(t.Context(), request); result.Failure == nil || result.Failure.Reason != ReasonInvalidLocation {
		t.Fatalf("result = %+v", result)
	}
}
