package workbench

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strconv"
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
	packageGoal        bool
	cleanupWhilePaused bool
	documentProbe      *javaDocumentProbe
	buildArchive       string
	buildSystem        string
	buildProject       string
	buildTask          string
	executablePaths    []string
	temporaryClasspath bool
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
	// Core's diagnostic queue is process-wide. These fixtures run serially;
	// scope terminal-fact assertions to this workflow rather than counting
	// a preceding cleanup-only fixture's successful runs as ours.
	drainContext, drainCancel := context.WithTimeout(context.Background(), 5*time.Second)
	_, drainErr := core.NewClient().DrainCoreEvents(drainContext)
	drainCancel()
	if drainErr != nil {
		t.Fatal(drainErr)
	}
	performance := newJavaPerformanceProbe(t, archive)
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
	var extraPath string
	var extraBefore map[string]string
	if fixture.buildArchive != "" {
		extraPlan, err := service.Installer.Prepare(ctx, plugininstall.Request{ArchivePath: fixture.buildArchive, Root: service.Root, Source: plugintrust.Disk})
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = service.Installer.Discard(extraPlan) })
		extra, err := service.Installer.Commit(extraPlan)
		if err != nil {
			t.Fatal(err)
		}
		if err := service.Manager.SetEnabled(extraPlan.ID, true); err != nil {
			t.Fatal(err)
		}
		extraPath, extraBefore = extra.Path, packageDigest(t, extra.Path)
	}
	before := packageDigest(t, installed.Path)
	closeAndVerify := func() {
		h.app.closeProject()
		awaitStateWithin(t, h, 30*time.Second, "closed project", func() bool { return h.app.project == nil })
		h.settle()
		assertPackageUnchanged(t, installed.Path, before)
		assertPackageUnchanged(t, mavenInstalled.Path, mavenBefore)
		if extraPath != "" {
			assertPackageUnchanged(t, extraPath, extraBefore)
		}
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
	for _, name := range fixture.executablePaths {
		if err := os.Chmod(filepath.Join(root, name), 0700); err != nil {
			t.Fatal(err)
		}
	}
	gitRun(t, root, "init")
	h.open(root)
	p := h.app.project
	if fixture.buildSystem != "" {
		h.app.loadBuildSystems(p)
		instance := awaitBuildModel(t, h, p, fixture.buildSystem, 120*time.Second)
		project := modelProjectNamed(instance.Model, fixture.buildProject)
		if project == nil {
			t.Fatalf("missing project %s: %+v", fixture.buildProject, instance.Model.Projects)
		}
		var taskID string
		for _, task := range instance.Model.Tasks {
			if task.ProjectID == project.ID && task.Name == fixture.buildTask {
				taskID = task.ID
				break
			}
		}
		if taskID == "" {
			t.Fatalf("missing task %s", fixture.buildTask)
		}
		output := runBuildTaskToEnd(t, h, p, project.ID, taskID, 90*time.Second)
		if !strings.Contains(output, "BUILD SUCCESSFUL") {
			t.Fatalf("Gradle compile: %s", output)
		}
		t.Log("Gradle multi-project model and compile succeeded")
	}
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
		if fixture.packageGoal {
			output := runBuildTaskToEnd(t, h, p, "", "package", 120*time.Second)
			if !strings.Contains(output, "BUILD SUCCESS") {
				t.Fatalf("WAR package failed: %s", output)
			}
		}
		if fixture.classVersion != 0 {
			assertJavaClassVersion(t, filepath.Join(root, fixture.classPath), fixture.classVersion)
		}
	}
	openedJava := time.Now()
	h.app.openFile(p, filepath.Join(root, fixture.mainPath))
	awaitStateWithin(t, h, 30*time.Second, "Java document", func() bool { return documentNamed(p, "Main.java") != nil })
	d := documentNamed(p, "Main.java")
	defer func() {
		if t.Failed() {
			retainJavaFailureLogs(t, service.Root, plan.ID)
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
				t.Logf("document sync: %+v", d.sync)
				for _, line := range server.logs[max(0, len(server.logs)-20):] {
					t.Logf("server log %s: %s", line.level, line.text)
				}
				probeContext, probeCancel := context.WithTimeout(context.Background(), 5*time.Second)
				methods, probeErr := service.ExecuteLanguageCommand(probeContext, server.session, "vscode.java.resolveMainMethod", []any{d.sync.uri}, 5*time.Second)
				probeCancel()
				t.Logf("late main methods: %s err=%v", methods, probeErr)
				testContext, testCancel := context.WithTimeout(context.Background(), 5*time.Second)
				tests, testErr := service.ExecuteLanguageCommand(testContext, server.session, "vscode.java.test.findTestTypesAndMethods", []any{d.sync.uri}, 5*time.Second)
				testCancel()
				t.Logf("late test items: %s err=%v", tests, testErr)
			}
		}
	}()
	awaitStateWithin(t, h, 120*time.Second, "JDT ready", func() bool {
		server, _ := h.app.documentSyncServer(d)
		return server != nil && server.isReady()
	})
	// LSP initialize can finish before the Java import's ServiceReady gate.
	// Wait for real editor actions through that bounded import, including cold
	// Gradle on Windows, rather than imposing a 15-second second startup budget.
	awaitStateWithin(t, h, 120*time.Second, "JDT editor actions", func() bool {
		if len(d.actions) > 0 {
			return true
		}
		return false
	})
	performance.elapsed("javaOpenToActions", openedJava)
	performance.sample(t, h, d, "ready")
	t.Logf("Run/Debug action ready: %s", d.actions[0].Title)
	if server, _ := h.app.documentSyncServer(d); server != nil {
		sampleContext, cancelSample := context.WithTimeout(context.Background(), 5*time.Second)
		sample, ok := pluginservice.SampleProcessTree(sampleContext, server.session.Session.ProcessID)
		cancelSample()
		if ok {
			t.Logf("JDT process tree RSS after import: %.1f MiB", float64(sample.MemoryBytes)/(1024*1024))
		}
	}
	// Real build plugins may prepend license headers. Locate the probes in the
	// document actually opened after the build, rather than stale fixture lines.
	openedContent, _ := d.view.Text()
	content = string(openedContent)
	completionLine, completionColumn := javaFixturePosition(t, content, "System.out.", true)
	breakpointLine, breakpointColumn := javaFixturePosition(t, content, "answer += 1;", false)
	if !d.view.GoToNavigation(completionLine, completionColumn, false) {
		t.Fatal("completion caret")
	}
	completionStarted := time.Now()
	h.app.startPluginCompletion(p, d, completionLine, completionColumn)
	awaitStateWithin(t, h, 30*time.Second, "JDT completion", func() bool { return len(h.app.semantics.completion.items) > 0 })
	performance.elapsed("firstCompletion", completionStarted)
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
	performance.completions(t, h, p, d, completionLine, completionColumn)
	if fixture.documentProbe != nil {
		fixture.documentProbe.prepare(t, h, p, d)
	}
	noticeBeforeRun := h.app.notice
	runStarted := time.Now()
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
			if !r.running {
				if !strings.Contains(strings.Join(r.output, ""), "java-result=42") {
					t.Fatalf("Java run exited without the expected result: %s %s", r.summary, strings.Join(r.output, ""))
				}
				if fixture.vmVersion != "" && !strings.Contains(strings.Join(r.output, ""), "vm="+fixture.vmVersion) {
					t.Fatalf("wrong project JVM: %s", strings.Join(r.output, ""))
				}
				return true
			}
		}
		return false
	})
	performance.elapsed("buildAndRun", runStarted)
	if fixture.temporaryClasspath {
		data, err := os.ReadFile(filepath.Join(root, "run-classpath.txt"))
		if err != nil || len(data) > 4096 {
			t.Fatalf("shortened classpath evidence: bytes=%d err=%v", len(data), err)
		}
		path := strings.TrimSpace(string(data))
		if filepath.Base(path) != "classpath.jar" {
			t.Fatalf("Windows launch did not use a manifest JAR: %s", path)
		}
		awaitStateWithin(t, h, 5*time.Second, "temporary classpath cleanup", func() bool {
			_, err := os.Stat(path)
			if err != nil && !os.IsNotExist(err) {
				t.Fatal(err)
			}
			return os.IsNotExist(err)
		})
		t.Log("Windows long classpath used a temporary manifest JAR and removed it after exit")
	}
	if fixture.classPath != "" {
		if _, err := os.Stat(filepath.Join(root, fixture.classPath)); err != nil {
			t.Fatalf("compiled class: %v", err)
		}
		if fixture.classVersion != 0 {
			assertJavaClassVersion(t, filepath.Join(root, fixture.classPath), fixture.classVersion)
		}
	}
	t.Log("compiled Main.class and ran java-result=42")
	if !d.view.GoToNavigation(breakpointLine, breakpointColumn, false) {
		t.Fatal("breakpoint caret")
	}
	h.app.toggleBreakpoint(p)
	logger.mu.Lock()
	logger.events = nil
	logger.mu.Unlock()
	t.Log("starting Java breakpoint session")
	debugStarted := time.Now()
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
	if frame := p.debug.frames[0]; !strings.Contains(frame.Name, "Main.main") || frame.Line != int64(breakpointLine+1) {
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
	performance.elapsed("debugToLocals", debugStarted)
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
	if fixture.documentProbe != nil {
		fixture.documentProbe.awaitBreakpoint(t, h, p)
		h.app.executeDebug(p, "continue")
	}
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
	if fixture.documentProbe != nil {
		h.app.executeDebug(p, "continue")
		fixture.documentProbe.awaitBreakpoint(t, h, p)
	}
	stopStarted := time.Now()
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
	performance.elapsed("debugStop", stopStarted)
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

	if fixture.buildSystem == "gradle" {
		workspace, exists := service.Contexts.ByPath(root)
		if !exists {
			t.Fatal("Gradle workspace context was lost")
		}
		params, err := json.Marshal(map[string]string{"workspaceRoot": root})
		if err != nil {
			t.Fatal(err)
		}
		reference, err := json.Marshal(workspace.ContextRef)
		if err != nil {
			t.Fatal(err)
		}
		settingsContext, settingsCancel := context.WithTimeout(context.Background(), 15*time.Second)
		answer, err := service.Host.Call(settingsContext, "io.github.lithe-idea.gradle-build", "languageImport.settings", params, reference, 10*time.Second)
		settingsCancel()
		if err != nil {
			t.Fatalf("real Gradle import settings: %v", err)
		}
		var settings struct {
			Settings map[string]string `json:"settings"`
		}
		if err := json.Unmarshal(answer, &settings); err != nil {
			t.Fatal(err)
		}
		if settings.Settings["java.import.gradle.user.home"] != os.Getenv("GRADLE_USER_HOME") || settings.Settings["java.import.gradle.java.home"] != strings.ReplaceAll(fixture.javaHome, "\\", "/") {
			t.Fatalf("Gradle source-backed import settings differ: %s", answer)
		}
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
		if fixture.buildSystem == "gradle" && event.Fields["code"] == "relay.provider_timed_out" {
			t.Fatal("cold Gradle settings relay timed out; a fallback is not full import verification")
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
	performance.sample(t, h, d, "workflowEnd")
	closeAndVerify()
}

// javaFixturePosition returns zero-based editor coordinates for a controlled
// ASCII probe in the current document; headers added by build tools are retained.
func javaFixturePosition(t *testing.T, text, probe string, after bool) (int, int) {
	t.Helper()
	offset := strings.Index(text, probe)
	if offset < 0 {
		t.Fatalf("fixture probe missing: %s", probe)
	}
	if after {
		offset += len(probe)
	}
	prefix := text[:offset]
	return strings.Count(prefix, "\n"), len(prefix) - strings.LastIndex(prefix, "\n") - 1
}

// Opt-in local evidence for public integration fixtures. Read only the known
// JDT log locations, at most 32 workspace entries and 1 MiB from each log.
func retainJavaFailureLogs(t *testing.T, pluginRoot, pluginID string) {
	t.Helper()
	output := os.Getenv("LITHE_TEST_JAVA_DIAGNOSTICS_DIR")
	if output == "" {
		return
	}
	if err := os.MkdirAll(output, 0700); err != nil {
		t.Logf("diagnostic directory: %v", err)
		return
	}
	base := filepath.Join(pluginRoot, ".state", pluginID)
	paths := []string{filepath.Join(base, "logs", "jdt.log")}
	entries, err := os.ReadDir(filepath.Join(base, "servers", "java", "workspaces"))
	if err != nil && !os.IsNotExist(err) {
		t.Logf("diagnostic workspace list: %v", err)
	}
	for _, entry := range entries[:min(len(entries), 32)] {
		if entry.IsDir() {
			paths = append(paths, filepath.Join(base, "servers", "java", "workspaces", entry.Name(), "data", ".metadata", ".log"))
		}
	}
	for index, path := range paths {
		file, err := os.Open(path)
		if os.IsNotExist(err) {
			continue
		}
		if err != nil {
			t.Logf("diagnostic log: %v", err)
			continue
		}
		data, readErr := io.ReadAll(io.LimitReader(file, 1<<20))
		closeErr := file.Close()
		if readErr != nil || closeErr != nil {
			t.Logf("diagnostic read=%v close=%v", readErr, closeErr)
			continue
		}
		name := strings.ReplaceAll(t.Name(), "/", "_") + "-" + strconv.Itoa(index) + ".log"
		if err := os.WriteFile(filepath.Join(output, name), data, 0600); err != nil {
			t.Logf("diagnostic write: %v", err)
		}
	}
}

// Check the emitted target after both the build tool and JDT's pre-run build.
// The read is fixed-size even when an upstream tool emits a large class file.
func assertJavaClassVersion(t *testing.T, path string, expected byte) {
	t.Helper()
	file, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	var header [8]byte
	_, readErr := io.ReadFull(file, header[:])
	closeErr := file.Close()
	if readErr != nil || closeErr != nil || [4]byte(header[:4]) != [4]byte{0xca, 0xfe, 0xba, 0xbe} || header[6] != 0 || header[7] != expected {
		t.Fatalf("class target: header=%x read=%v close=%v expected major=%d", header, readErr, closeErr, expected)
	}
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
