package workbench

import (
	"context"
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
	content := "package demo;\npublic class Main {\n public static void main(String[] args) {\n  int answer = 41;\n  answer += 1;\n  System.out.println(org.apache.commons.lang3.StringUtils.reverse(\"avaj\") + \"-result=\" + answer);\n }\n}\n"
	writeFixture(t, root, map[string]string{
		"pom.xml":                      `<project xmlns="http://maven.apache.org/POM/4.0.0"><modelVersion>4.0.0</modelVersion><groupId>demo</groupId><artifactId>java-pilot</artifactId><version>1.0</version><properties><maven.compiler.release>17</maven.compiler.release><maven.compiler.source>17</maven.compiler.source><maven.compiler.target>17</maven.compiler.target><project.build.sourceEncoding>UTF-8</project.build.sourceEncoding></properties><dependencies><dependency><groupId>org.apache.commons</groupId><artifactId>commons-lang3</artifactId><version>3.17.0</version></dependency></dependencies></project>`,
		"src/main/java/demo/Main.java": content,
	})
	gitRun(t, root, "init")
	h.open(root)
	p := h.app.project
	h.app.loadBuildSystems(p)
	awaitBuildModel(t, h, p, "maven", 90*time.Second)
	output := runBuildTaskToEnd(t, h, p, "", "compile", 90*time.Second)
	if !strings.Contains(output, "BUILD SUCCESS") {
		t.Fatalf("Maven compile: %s", output)
	}
	t.Log("Maven compile succeeded")
	h.app.openFile(p, filepath.Join(root, "src/main/java/demo/Main.java"))
	awaitStateWithin(t, h, 30*time.Second, "Java document", func() bool { return documentNamed(p, "Main.java") != nil })
	d := documentNamed(p, "Main.java")
	defer func() {
		if t.Failed() {
			t.Logf("document language=%s actions=%d ", d.languageID, len(d.actions))
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
	h.app.runEditorAction(p, d, d.actions[0], -1)
	awaitStateWithin(t, h, 90*time.Second, "Java run", func() bool {
		for _, r := range p.build.runs {
			if !r.running && strings.Contains(strings.Join(r.output, ""), "java-result=42") {
				return true
			}
		}
		return false
	})
	if _, err := os.Stat(filepath.Join(root, "target/classes/demo/Main.class")); err != nil {
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
	h.app.closeProject()
	awaitStateWithin(t, h, 30*time.Second, "closed project", func() bool { return h.app.project == nil })
	h.settle()
	assertPackageUnchanged(t, installed.Path, before)
	assertPackageUnchanged(t, mavenInstalled.Path, mavenBefore)
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
