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
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginhost"
	"github.com/1lck/Lithe-IDEA/desktop/internal/plugininstall"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/1lck/Lithe-IDEA/desktop/internal/plugintrust"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/vivaui/viva/app"
)

// Opt-in integration: install the actual Java archive, then drive the same editor,
// run and DAP paths as the native window. All Java knowledge lives in the archive.
func TestJavaPluginMavenWorkflow(t *testing.T) {
	runJavaPluginWorkflow(t, standardJavaFixture())
}

func TestJavaPluginCleanupWhilePaused(t *testing.T) {
	fixture := standardJavaFixture()
	fixture.cleanupWhilePaused = true
	runJavaPluginWorkflow(t, fixture)
}

type javaWorkflowFixture struct {
	files              map[string]string
	mainPath           string
	classPath          string
	javaHome           string
	vmVersion          string
	classVersion       byte
	noMaven            bool
	projectRoot        string
	expectBuildRefused bool
	testGoal           bool
	cleanupWhilePaused bool
}

func runJavaPluginWorkflow(t *testing.T, fixture javaWorkflowFixture) {
	t.Helper()
	if fixture.javaHome != "" {
		t.Setenv("JAVA_HOME", fixture.javaHome)
	}

	archive := os.Getenv("LITHE_TEST_JAVA_PLUGIN_ARCHIVE")
	if archive == "" {
		t.Skip("set LITHE_TEST_JAVA_PLUGIN_ARCHIVE to the built Java plugin zip")
	}
	mavenArchive := os.Getenv("LITHE_TEST_MAVEN_PLUGIN_ARCHIVE")
	if mavenArchive == "" {
		t.Skip("set LITHE_TEST_MAVEN_PLUGIN_ARCHIVE to the compatible Maven plugin zip")
	}
	preferences := store.At(t.TempDir())
	if err := os.WriteFile(filepath.Join(preferences.Dir(), settingsFile), []byte(`{"theme":"dark","autoSave":false}`), 0600); err != nil {
		t.Fatal(err)
	}
	kernel := &testKernel{Client: core.NewClient()}
	h := newHarnessWithOptions(t, Options{Kernel: kernel, PluginKernel: kernel, PluginRoot: t.TempDir(), Store: preferences, Languages: []string{"en"}})
	if h.app.plugins == nil {
		t.Fatal("plugin service unavailable")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	service := h.app.plugins
	t.Cleanup(func() {
		// Assertions can abort while a Run is paused or a document is dirty.
		// This fixture owns the project: bypass interactive save/exit prompts.
		var sessionID string
		if p := h.app.project; p != nil {
			if session := p.debug.activeSession(); session != nil {
				sessionID = session.id
			}
			h.app.finishCloseProject(p, nil)
		}
		h.settle()
		service.Runs.StopAll()
		if active := service.Runs.Active(); len(active) != 0 {
			t.Errorf("fixture cleanup left runs: %v", active)
		}
		if sessionID != "" {
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			_, err := kernel.ReceiveDebug(ctx, sessionID, nil)
			var failure *core.Error
			if !errors.As(err, &failure) || failure.Code != core.CodeInvalidRequest || failure.Message != "Debug session was not found." {
				t.Errorf("fixture cleanup did not remove its Core debug session: %v", err)
			}
			t.Log("unconditional cleanup: no active runs; Core debug session removed")
		}
	})
	plan, err := service.Installer.Prepare(ctx, plugininstall.Request{ArchivePath: archive, Root: service.Root, Source: plugintrust.Disk})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = service.Installer.Discard(plan) })
	installed, err := service.Installer.Commit(plan)
	if err != nil {
		t.Fatal(err)
	}
	if err := service.Manager.SetEnabled(plan.ID, true); err != nil {
		t.Fatal(err)
	}
	mavenPlan, err := service.Installer.Prepare(ctx, plugininstall.Request{ArchivePath: mavenArchive, Root: service.Root, Source: plugintrust.Disk})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = service.Installer.Discard(mavenPlan) })
	mavenInstalled, err := service.Installer.Commit(mavenPlan)
	if err != nil {
		t.Fatal(err)
	}
	if err := service.Manager.SetEnabled(mavenPlan.ID, true); err != nil {
		t.Fatal(err)
	}
	mavenBefore := packageDigest(t, mavenInstalled.Path)
	before := packageDigest(t, installed.Path)
	closeAndVerify := func() {
		h.app.closeProject()
		awaitStateWithin(t, h, 30*time.Second, "closed project", func() bool { return h.app.project == nil })
		h.settle()
		assertPackageUnchanged(t, installed.Path, before)
		assertPackageUnchanged(t, mavenInstalled.Path, mavenBefore)
	}
	logger := &treeRecordingLog{}
	h.app.logSink = logger
	t.Cleanup(func() {
		if t.Failed() {
			logger.mu.Lock()
			defer logger.mu.Unlock()
			for _, event := range logger.events {
				t.Logf("host event: %s %v", event.Event, event.Fields)
			}
		}
	})
	h.app.reloadPluginLanguages()
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	content := fixture.files[fixture.mainPath]
	if fixture.projectRoot != "" {
		copyHistoricalJavaProject(t, fixture.projectRoot, root)
	}
	writeFixture(t, root, fixture.files)
	gitRun(t, root, "init")
	h.open(root)
	p := h.app.project
	if !fixture.noMaven {
		h.app.loadBuildSystems(p)
		awaitBuildModel(t, h, p, "maven", 90*time.Second)
		output := runBuildTaskToEnd(t, h, p, "", "compile", 90*time.Second)
		if !strings.Contains(output, "BUILD SUCCESS") {
			t.Fatalf("Maven compile: %s", output)
		}
		t.Log("Maven compile succeeded")
		if fixture.testGoal {
			output := runBuildTaskToEnd(t, h, p, "", "test", 90*time.Second)
			if !strings.Contains(output, "BUILD SUCCESS") || !strings.Contains(output, "Tests run: 1") {
				t.Fatalf("legacy Maven test goal: %s", output)
			}
			t.Log("legacy test framework: Maven test goal passed one test")
		}
		if fixture.classVersion != 0 {
			compiled, err := os.ReadFile(filepath.Join(root, fixture.classPath))
			if err != nil || len(compiled) < 8 || compiled[7] != fixture.classVersion {
				t.Fatalf("Maven class target: header=%x err=%v, expected major %d", compiled[:min(len(compiled), 8)], err, fixture.classVersion)
			}
		}
	}
	h.app.openFile(p, filepath.Join(root, fixture.mainPath))
	awaitStateWithin(t, h, 30*time.Second, "Java document", func() bool { return documentNamed(p, "Main.java") != nil })
	d := documentNamed(p, "Main.java")
	defer func() {
		if t.Failed() {
			t.Logf("document language=%s actions=%d ", d.languageID, len(d.actions))
			t.Logf("notice=%s debug state=%s failure=%s", h.app.notice, p.debug.state, p.debug.failure)
			t.Logf("JDT problems: %v", problemMessages(h.app))
			for _, run := range p.build.runs {
				t.Logf("run: running=%v summary=%s output=%s", run.running, run.summary, strings.Join(run.output, ""))
			}
			ctx, cancel := context.WithTimeout(context.Background(), time.Second)
			defer cancel()
			events, err := core.NewClient().DrainCoreEvents(ctx)
			t.Logf("Core diagnostics: %+v err=%v", events, err)
			if backend := h.app.plugins.Host.Running(plan.ID); backend != nil {
				t.Logf("backend grants: %v", backend.Session.Granted)
			}
			for id, server := range h.app.pluginServers {
				t.Logf("server %s ready=%v", id, server.isReady())
			}
		}
	}()
	awaitStateWithin(t, h, 120*time.Second, "JDT ready", func() bool {
		server, _ := h.app.documentSyncServer(d)
		return server != nil && server.isReady()
	})
	awaitStateWithin(t, h, 15*time.Second, "JDT editor actions", func() bool {
		if len(d.actions) > 0 {
			return true
		}
		return false
	})
	t.Logf("Run/Debug action ready: %s", d.actions[0].Title)
	if server, _ := h.app.documentSyncServer(d); server != nil {
		sampleContext, cancelSample := context.WithTimeout(context.Background(), 5*time.Second)
		sample, ok := pluginservice.SampleProcessTree(sampleContext, server.session.Session.ProcessID)
		cancelSample()
		if ok {
			t.Logf("JDT process tree RSS after import: %.1f MiB", float64(sample.MemoryBytes)/(1024*1024))
		}
	}
	if !d.view.GoToNavigation(5, 13, false) {
		t.Fatal("completion caret")
	}
	h.app.startPluginCompletion(p, d, 5, 13)
	awaitStateWithin(t, h, 30*time.Second, "JDT completion", func() bool { return len(h.app.semantics.completion.items) > 0 })
	found := false
	for _, item := range h.app.semantics.completion.items {
		if strings.Contains(item.Label, "println") {
			found = true
		}
	}
	if !found {
		t.Fatalf("no println completion: %+v", h.app.semantics.completion.items)
	}
	t.Logf("JDT completion: %d candidates including println", len(h.app.semantics.completion.items))
	h.app.closeSemanticCompletion()
	noticeBeforeRun := h.app.notice
	h.app.runEditorAction(p, d, d.actions[0], -1)
	if fixture.expectBuildRefused {
		// This is an explicit compatibility-boundary test, not a passing full
		// workflow: the current bundled ECJ rejects source levels below Java 8.
		awaitStateWithin(t, h, 30*time.Second, "legacy build refusal", func() bool { return h.app.notice != noticeBeforeRun })
		if len(p.build.runs) != 0 {
			t.Fatal("unsupported build launched a process")
		}
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		events, err := core.NewClient().DrainCoreEvents(ctx)
		cancel()
		if err != nil {
			t.Fatal(err)
		}
		failures := 0
		for _, event := range events.Events {
			if event.Channel == "plugins/"+plan.ID+"/host" && event.Fields["operation"] == "java.runAction" {
				if event.Event != "plugins.operation.failed" || event.Fields["code"] != "run.build_failed" || event.Level != core.LevelError {
					t.Fatalf("unexpected legacy build result: %+v", event)
				}
				failures++
			}
		}
		if failures != 1 {
			t.Fatalf("legacy build refusal count: %d", failures)
		}
		t.Log("COMPATIBILITY BOUNDARY: Maven compile and completion work; Run/Debug remain unsupported at this source level")
		closeAndVerify()
		return
	}
	awaitStateWithin(t, h, 90*time.Second, "Java run", func() bool {
		if h.app.notice != noticeBeforeRun {
			t.Fatalf("Java run refused: %s", h.app.notice)
		}
		for _, r := range p.build.runs {
			if !r.running && strings.Contains(strings.Join(r.output, ""), "java-result=42") {
				if fixture.vmVersion != "" && !strings.Contains(strings.Join(r.output, ""), "vm="+fixture.vmVersion) {
					t.Fatalf("wrong project JVM: %s", strings.Join(r.output, ""))
				}
				return true
			}
		}
		return false
	})
	if _, err := os.Stat(filepath.Join(root, fixture.classPath)); err != nil {
		t.Fatalf("compiled class: %v", err)
	}
	t.Log("compiled Main.class and ran java-result=42")
	if !d.view.GoToNavigation(4, 2, false) {
		t.Fatal("breakpoint caret")
	}
	h.app.toggleBreakpoint(p)
	logger.mu.Lock()
	logger.events = nil
	logger.mu.Unlock()
	t.Log("starting Java breakpoint session")
	h.app.runEditorAction(p, d, d.actions[0], 0)
	awaitStateWithin(t, h, 90*time.Second, "Java breakpoint", func() bool {
		if len(p.build.runs) > 1 {
			r := p.build.runs[len(p.build.runs)-1]
			if !r.running {
				t.Fatalf("debug run exited: %s %s", r.summary, strings.Join(r.output, ""))
			}
		}

		logger.mu.Lock()
		for _, event := range logger.events {
			if event.Event == operationFailedEvent {
				logger.mu.Unlock()
				t.Fatalf("host operation failed: %v", event.Fields)
			}
		}
		logger.mu.Unlock()
		if p.debug.failure != "" {
			t.Fatalf("debug: %s", p.debug.failure)
		}
		return p.debug.state == "paused" && len(p.debug.frames) > 0
	})
	if frame := p.debug.frames[0]; !strings.Contains(frame.Name, "Main.main") || frame.Line != 5 {
		t.Fatalf("wrong breakpoint: %+v", frame)
	}
	t.Logf("Java paused in %s at line %d", p.debug.frames[0].Name, p.debug.frames[0].Line)
	awaitStateWithin(t, h, 15*time.Second, "Java local variable", func() bool {
		for _, scope := range p.debug.vars.scopes {
			if scope.container != nil {
				if node := findDebugVariable(scope.container.nodes, "answer"); node != nil {
					return node.value == "41"
				}
			}
		}
		return false
	})
	t.Log("Java local variable answer=41")
	if fixture.cleanupWhilePaused {
		// Return without the success-path closeAndVerify, just as an assertion
		// failure would. t.Cleanup must stop the paused JVM and destroy Core state.
		if p.debug.activeSession() == nil || len(service.Runs.Active()) == 0 {
			t.Fatal("cleanup probe has no active debug session and owned run")
		}
		t.Log("leaving the paused workflow to its unconditional fixture cleanup")
		return
	}
	h.app.executeDebug(p, "continue")
	awaitStateWithin(t, h, 30*time.Second, "debuggee exit", func() bool { return p.debug.activeSession() == nil })
	awaitStateWithin(t, h, 15*time.Second, "run exit notifications", func() bool {
		for _, r := range p.build.runs {
			if r.running {
				return false
			}
		}
		return true
	})
	t.Log("Java run and debug session exited")

	// Stop a second live debuggee through the same control as the toolbar.
	h.app.runEditorAction(p, d, d.actions[0], 0)
	awaitStateWithin(t, h, 90*time.Second, "second Java breakpoint", func() bool {
		return p.debug.activeSession() != nil && p.debug.state == "paused"
	})
	h.app.stopDebugByUser(p)
	awaitStateWithin(t, h, 30*time.Second, "cancelled Java debuggee", func() bool {
		if p.debug.activeSession() != nil {
			return false
		}
		for _, r := range p.build.runs {
			if r.running {
				return false
			}
		}
		return true
	})
	t.Log("Java debug cancellation stopped the run")

	// A failed compilation must never execute the successful build's old class.
	d.view.SelectAll()
	input := d.view.TextInput(app.TextInputContext{ID: d.hit})
	if _, err := input.OnEvent(app.TextEvent{Kind: app.TextInsert, Text: strings.Replace(content, "int answer = 41;", "int answer = missing;", 1)}); err != nil {
		t.Fatal(err)
	}
	h.app.saveDocument(p, d.id)
	awaitStateWithin(t, h, 30*time.Second, "invalid Java saved and recollected", func() bool {
		return !d.dirty() && len(d.actions) > 0 && d.actions[0].Version() == d.view.Revision()
	})
	runsBeforeFailure := len(p.build.runs)
	noticeBeforeFailure := h.app.notice
	h.app.runEditorAction(p, d, d.actions[0], -1)
	awaitStateWithin(t, h, 90*time.Second, "Java compile failure", func() bool { return h.app.notice != noticeBeforeFailure })
	if len(p.build.runs) != runsBeforeFailure {
		t.Fatal("compiler errors launched stale bytecode")
	}

	// Inspect the real Core facts before a log-store writer consumes them. Collection
	// is high frequency and must not add success INFO; user runs own one terminal fact.
	logCtx, cancelLogs := context.WithTimeout(context.Background(), 5*time.Second)
	events, err := core.NewClient().DrainCoreEvents(logCtx)
	cancelLogs()
	if err != nil {
		t.Fatal(err)
	}
	successes, failures := 0, 0
	for _, event := range events.Events {
		if event.Channel != "plugins/"+plan.ID+"/host" {
			continue
		}
		operation, _ := event.Fields["operation"].(string)
		if event.Event == "plugins.operation.finished" && operation == "java.collectActions" {
			t.Fatal("high-frequency collection emitted success INFO")
		}
		if operation != "java.runAction" {
			continue
		}
		if event.Op == "" {
			t.Fatal("run diagnostic lost its operation identity")
		}
		switch event.Event {
		case "plugins.operation.finished":
			if event.Level != core.LevelInfo {
				t.Fatalf("run success level: %s", event.Level)
			}
			successes++
		case "plugins.operation.failed":
			if event.Level != core.LevelError || event.Fields["code"] != "run.build_failed" {
				t.Fatalf("compile failure diagnostic: %+v", event)
			}
			failures++
		}
	}
	if successes != 3 || failures != 1 {
		t.Fatalf("run terminal diagnostics: successes=%d failures=%d; events=%+v", successes, failures, events)
	}
	t.Log("compiler errors blocked stale class; Core logging success/failure and collection suppression verified")
	closeAndVerify()
}

func TestJavaPluginCurrentManifestContract(t *testing.T) {
	path := os.Getenv("LITHE_TEST_JAVA_PLUGIN_MANIFEST")
	if path == "" {
		t.Skip("set LITHE_TEST_JAVA_PLUGIN_MANIFEST")
	}
	manifest, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if _, err := core.NewClient().ValidatePluginManifest(ctx, manifest, pluginhost.Declared()); err != nil {
		t.Fatal(err)
	}
}
