package workbench

import (
	"archive/zip"
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/plugininstall"
	"github.com/1lck/Lithe-IDEA/desktop/internal/plugintrust"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/vivaui/viva/gfx"
)

// Real JDT and a jar generated entirely from this test's own sources: no
// proprietary classes, source attachments, network dependencies or execution.
func TestJavaPluginBinaryNavigation(t *testing.T) {
	archive := os.Getenv("LITHE_TEST_JAVA_PLUGIN_ARCHIVE")
	if archive == "" {
		t.Skip("Java integration archive required")
	}
	home := os.Getenv("JAVA_HOME")
	if home == "" {
		t.Fatal("JAVA_HOME with javac is required")
	}
	javac := filepath.Join(home, "bin", "javac")
	if runtime.GOOS == "windows" {
		javac += ".exe"
	}
	library := t.TempDir()
	writeFixture(t, library, map[string]string{
		"library/Slow.java":       "package library; public class Slow {}",
		"library/Entity.java":     "package library;\npublic class Entity {\n public String label() { return \"entity\"; }\n public EntitySet owner() { return null; }\n}\n",
		"library/Incomplete.java": "package library;\npublic class Incomplete {\n public static class Missing {}\n public String legacyName() { return \"outer\"; }\n}\n",
		"library/EntitySet.java":  "package library;\npublic class EntitySet {\n public String label() { return \"set\"; }\n public Entity first() { return null; }\n}\n",
	})
	classes := filepath.Join(library, "classes")
	if err := os.MkdirAll(classes, 0700); err != nil {
		t.Fatal(err)
	}
	compileCtx, compileCancel := context.WithTimeout(context.Background(), 30*time.Second)
	command := exec.CommandContext(compileCtx, javac, "--release", "8", "-g", "-d", classes, filepath.Join(library, "library/Entity.java"), filepath.Join(library, "library/EntitySet.java"), filepath.Join(library, "library/Incomplete.java"), filepath.Join(library, "library/Slow.java"))
	command.WaitDelay = 2 * time.Second
	output, err := command.CombinedOutput()
	compileCancel()
	if err != nil {
		t.Fatalf("compile own binary fixture: %v: %s", err, output)
	}
	preferenceDir := t.TempDir()
	if err := os.WriteFile(filepath.Join(preferenceDir, settingsFile), []byte(`{"theme":"dark"}`), 0600); err != nil {
		t.Fatal(err)
	}
	kernel := &binaryNavigationKernel{testKernel: &testKernel{Client: core.NewClient()}}
	h := newHarnessWithOptions(t, Options{Kernel: kernel, PluginKernel: kernel, PluginRoot: t.TempDir(), Store: store.At(preferenceDir), Languages: []string{"en"}})
	service := h.app.plugins
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	plan, err := service.Installer.Prepare(ctx, plugininstall.Request{ArchivePath: archive, Root: service.Root, Source: plugintrust.Disk})
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		if e := service.Installer.Discard(plan); e != nil {
			t.Error(e)
		}
	}()
	installed, err := service.Installer.Commit(plan)
	if err != nil {
		t.Fatal(err)
	}
	if err = service.Manager.SetEnabled(plan.ID, true); err != nil {
		t.Fatal(err)
	}
	before := packageDigest(t, installed.Path)
	h.app.reloadPluginLanguages()
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	source := "package app;\nimport library.Entity;\nimport library.EntitySet;\nimport library.Incomplete;\nimport library.Slow;\npublic class Main {\n public static void main(String[] args) {}\n String labels(Entity item, EntitySet set) {return item.label() + set.label();}\n void slow(Slow value) {}\n String legacy(Incomplete old) { return old.legacyName(); }\n}\n"
	writeFixture(t, root, map[string]string{
		".project":                             `<projectDescription><name>binary-navigation</name><buildSpec><buildCommand><name>org.eclipse.jdt.core.javabuilder</name></buildCommand></buildSpec><natures><nature>org.eclipse.jdt.core.javanature</nature></natures></projectDescription>`,
		".classpath":                           `<classpath><classpathentry kind="src" path="src"/><classpathentry kind="lib" path="lib/library.jar"/><classpathentry kind="con" path="org.eclipse.jdt.launching.JRE_CONTAINER"/><classpathentry kind="output" path="classes"/></classpath>`,
		".settings/org.eclipse.jdt.core.prefs": "eclipse.preferences.version=1\norg.eclipse.jdt.core.compiler.source=17\norg.eclipse.jdt.core.compiler.compliance=17\norg.eclipse.jdt.core.compiler.codegen.targetPlatform=17\n",
		"src/app/Main.java":                    source,
	})
	if err = os.MkdirAll(filepath.Join(root, "lib"), 0700); err != nil {
		t.Fatal(err)
	}
	file, err := os.Create(filepath.Join(root, "lib/library.jar"))
	if err != nil {
		t.Fatal(err)
	}
	writer := zip.NewWriter(file)
	for _, name := range []string{"Entity", "EntitySet", "Incomplete", "Slow"} {
		bytes, e := os.ReadFile(filepath.Join(classes, "library", name+".class"))
		if e != nil {
			writer.Close()
			file.Close()
			t.Fatal(e)
		}
		entry, e := writer.Create("library/" + name + ".class")
		if e == nil {
			_, e = entry.Write(bytes)
		}
		if e != nil {
			writer.Close()
			file.Close()
			t.Fatal(e)
		}
	}
	zipErr, fileErr := writer.Close(), file.Close()
	if zipErr != nil || fileErr != nil {
		t.Fatalf("close binary jar: %v / %v", zipErr, fileErr)
	}
	t.Cleanup(func() {
		if p := h.app.project; p != nil {
			h.app.finishCloseProject(p, nil)
			awaitStateWithin(t, h, 30*time.Second, "binary project closed", func() bool { return h.app.project == nil })
		}
		assertPackageUnchanged(t, installed.Path, before)
	})
	h.open(root)
	p := h.app.project
	t.Cleanup(func() {
		if t.Failed() {
			t.Logf("notice=%s", h.app.notice)
			kernel.mu.Lock()
			defer kernel.mu.Unlock()
			for _, e := range kernel.events {
				t.Logf("definition %s %s => %s error=%s", e.URI, e.OperationID, e.Result, e.Error)
			}
		}
	})
	mainPath := filepath.Join(root, "src/app/Main.java")
	h.app.openFile(p, mainPath)
	awaitStateWithin(t, h, 120*time.Second, "Java binary project ready", func() bool {
		d := documentNamed(p, "Main.java")
		return d != nil && len(d.actions) > 0 && service.HasContentProvider(p.root, "jdt://contents/library")
	})
	jump := func(d *document, needle, target, symbol string) {
		t.Helper()
		h.app.selectDocument(p, d.id)
		h.app.invalidator.Invalidate()
		if err := h.driver.Pump(); err != nil {
			t.Fatal(err)
		}
		text, _ := d.view.Text()
		at := strings.Index(string(text), needle)
		if at < 0 {
			t.Fatalf("missing fixture symbol %q", needle)
		}
		// Search strings begin at the symbol, including member calls' method name.
		prefix := string(text[:at+1])
		line := strings.Count(prefix, "\n")
		column := len(prefix) - strings.LastIndex(prefix, "\n") - 1
		d.view.GoToNavigation(line, column, false)
		h.app.invalidator.Invalidate()
		if err := h.driver.Pump(); err != nil {
			t.Fatal(err)
		}

		if err := h.driver.Key(gfx.KeyF12, 0); err != nil {
			t.Fatal(err)
		}
		awaitStateWithin(t, h, 30*time.Second, "binary target "+target, func() bool {
			v := p.selectedDocument(p.docs.group)
			return v != nil && v.virtual && strings.Contains(v.path, "/"+target+".java")
		})
		v := p.selectedDocument(p.docs.group)
		content, _ := v.view.Text()
		line, _ = v.view.CaretUTF16()
		lines := strings.Split(string(content), "\n")
		if !v.view.ReadOnly() || v.languageID != "java" || line < 0 || line >= len(lines) || !strings.Contains(lines[line], symbol) {
			t.Fatalf("binary target %s: language=%s readOnly=%v line=%d expected %s", target, v.languageID, v.view.ReadOnly(), line+1, symbol)
		}
	}
	main := p.docs.byPath(mainPath)
	jump(main, "label();", "EntitySet", "label")
	jump(main, "Entity item", "Entity", "Entity")
	jump(main, "EntitySet set", "EntitySet", "EntitySet")
	jump(main, "label() +", "Entity", "label")
	jump(main, "label();", "EntitySet", "label")
	var entity *document
	for _, d := range p.docs.list {
		if d.virtual && strings.Contains(d.path, "/Entity.java") {
			entity = d
		}
	}
	if entity == nil {
		t.Fatal("missing entity view")
	}
	jump(entity, "EntitySet owner", "EntitySet", "EntitySet")
	set := p.selectedDocument(p.docs.group)
	jump(set, "Entity first", "Entity", "Entity")
	jump(main, "Incomplete old", "Incomplete", "Incomplete")
	jump(main, "legacyName();", "Incomplete", "legacyName")
	// Hold the real class-content response, move the visible caret, then release it.
	// An obsolete navigation must finish without opening a tab or stealing focus.
	gate := &binaryContentGate{entered: make(chan struct{}), release: make(chan struct{})}
	defer gate.releaseOnce.Do(func() { close(gate.release) })
	kernel.mu.Lock()
	kernel.gate = gate
	kernel.mu.Unlock()
	h.app.selectDocument(p, main.id)
	text, _ := main.view.Text()
	at := strings.Index(string(text), "Slow value") + 1
	prefix := string(text[:at])
	line := strings.Count(prefix, "\n")
	column := len(prefix) - strings.LastIndex(prefix, "\n") - 1
	main.view.GoToNavigation(line, column, false)
	h.app.invalidator.Invalidate()
	if err := h.driver.Pump(); err != nil {
		t.Fatal(err)
	}
	if err := h.driver.Key(gfx.KeyF12, 0); err != nil {
		t.Fatal(err)
	}
	awaitValueWithin(t, h, 20*time.Second, gate.entered, "class content response held")
	if err := h.driver.Key(gfx.KeyRight, 0); err != nil {
		t.Fatal(err)
	}
	gate.releaseOnce.Do(func() { close(gate.release) })
	awaitStateWithin(t, h, 20*time.Second, "obsolete class navigation finished", func() bool { return h.app.contentOpen == nil })
	h.app.invalidator.Invalidate()
	if err := h.driver.Pump(); err != nil {
		t.Fatal(err)
	}
	if p.selectedDocument(p.docs.group) != main {
		t.Fatal("obsolete class navigation stole focus")
	}
	for _, d := range p.docs.list {
		if d.virtual && strings.Contains(d.path, "/Slow.java") {
			t.Fatal("obsolete class navigation opened a tab")
		}
	}
	if len(problemMessages(h.app)) != 0 {
		t.Fatalf("fixture has diagnostics: %v", problemMessages(h.app))
	}
}

// Keep only this fixture's bounded definition results for failure diagnostics.
type binaryNavigationKernel struct {
	*testKernel
	mu     sync.Mutex
	events []core.BackendEvent
	gate   *binaryContentGate
}

func (k *binaryNavigationKernel) WaitBackendEvents(ctx context.Context, session string, timeout int) ([]core.BackendEvent, error) {
	events, err := k.Client.WaitBackendEvents(ctx, session, timeout)
	for _, e := range events {
		if e.Type == "requestCompleted" && e.Method == "java/classFileContents" {
			k.mu.Lock()
			gate := k.gate
			k.gate = nil
			k.mu.Unlock()
			if gate != nil {
				close(gate.entered)
				timer := time.NewTimer(15 * time.Second)
				select {
				case <-gate.release:
				case <-ctx.Done():
					timer.Stop()
					return nil, ctx.Err()
				case <-timer.C:
					return nil, fmt.Errorf("class response gate timed out")
				}
				timer.Stop()
			}
		}
		if e.Type == "requestCompleted" && e.Method == "textDocument/definition" {
			k.mu.Lock()
			if len(k.events) < 32 {
				k.events = append(k.events, e)
			}
			k.mu.Unlock()
		}
	}
	return events, err
}

// This gate is consumed once, released on all assertion paths, and times out on
// the backend worker rather than blocking the UI thread.
type binaryContentGate struct {
	entered     chan struct{}
	release     chan struct{}
	releaseOnce sync.Once
}
