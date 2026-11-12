package pluginservice

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginbackend"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginlsp"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginmanager"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginpkg"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

// TestJavaSupportStartsJDTLSAndPublishesDiagnostics runs the real Java Support
// package: the host starts its backend, the backend answers java.resolveLaunch,
// Core decodes the answer, and JDT LS starts and reports a compile error.
//
// It needs a built package (the plugin repository's scripts/build-package.sh) and
// a few minutes, so it runs only when LITHE_JAVA_PLUGIN_PACKAGE names the package
// directory. The package is read-only here: nothing is written below it.
func TestJavaSupportStartsJDTLSAndPublishesDiagnostics(t *testing.T) {
	packageDirectory := os.Getenv("LITHE_JAVA_PLUGIN_PACKAGE")
	if packageDirectory == "" {
		t.Skip("LITHE_JAVA_PLUGIN_PACKAGE is not set")
	}
	client := core.NewClient()
	root := t.TempDir()
	service, err := Open(client, store.At(t.TempDir()), root)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { service.Host.StopAll() })

	manifest, err := os.ReadFile(filepath.Join(packageDirectory, pluginpkg.ManifestFile))
	if err != nil {
		t.Fatal(err)
	}
	var identity struct {
		ID      string `json:"id"`
		Version string `json:"version"`
	}
	if err := json.Unmarshal(manifest, &identity); err != nil {
		t.Fatal(err)
	}
	// Install a copy where the plugin manager looks, so the backend is found the
	// way a user installation is. The original package is never touched.
	installed := filepath.Join(root, identity.ID, identity.Version)
	if err := os.MkdirAll(filepath.Dir(installed), 0o700); err != nil {
		t.Fatal(err)
	}
	if output, err := exec.Command("cp", "-R", packageDirectory, installed).CombinedOutput(); err != nil {
		t.Fatalf("copy package: %v: %s", err, output)
	}
	if err := service.Manager.SetEnabled(identity.ID, true); err != nil {
		t.Fatal(err)
	}
	var entries []pluginmanager.Entry
	if entries, err = service.Manager.Installed(); err != nil {
		t.Fatal(err)
	}

	workspace := t.TempDir()
	source := filepath.Join(workspace, "Main.java")
	text := "public class Main {\n    public static void main(String[] args) {\n        int broken = \"not a number\";\n    }\n}\n"
	if err := os.WriteFile(source, []byte(text), 0o600); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Minute)
	defer cancel()
	rootURI, err := client.PluginDocumentURI(ctx, workspace, "auto")
	if err != nil {
		t.Fatal(err)
	}
	session, err := service.StartLanguageServer(ctx, entries, "java", BackendRequest{
		RootURI: rootURI, WorkingDirectory: workspace, Architecture: core.PluginArchitecture(),
	})
	if err != nil || session == nil {
		t.Fatalf("start: %v (session %v)", err, session)
	}
	defer func() {
		stopCtx, stop := context.WithTimeout(context.Background(), 30*time.Second)
		defer stop()
		if err := service.StopLanguageServer(stopCtx, session); err != nil {
			t.Errorf("stop: %v", err)
		}
	}()

	ready := make(chan struct{})
	diagnostics := make(chan core.PluginDiagnosticsEvent, 8)
	serveCtx, stopServe := context.WithCancel(ctx)
	defer stopServe()
	go func() {
		_ = service.ServeLanguageSession(serveCtx, session, func(event core.BackendEvent) {
			switch event.Type {
			case "stateChanged":
				if event.State == "ready" {
					select {
					case <-ready:
					default:
						close(ready)
					}
				}
			case pluginbackend.EventDiagnostics:
				if decoded, err := core.PluginDiagnosticsFromEvent(event); err == nil {
					select {
					case diagnostics <- decoded:
					default:
					}
				}
			}
		})
	}()
	select {
	case <-ready:
	case <-time.After(5 * time.Minute):
		t.Fatal("JDT LS did not become ready")
	}
	uri, err := client.PluginDocumentURI(ctx, source, "auto")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := session.Documents.Open(ctx, pluginlsp.Document{URI: uri, LanguageID: "java", Text: text}); err != nil {
		t.Fatalf("open document: %v", err)
	}
	deadline := time.After(3 * time.Minute)
	for {
		select {
		case event := <-diagnostics:
			if len(event.Diagnostics) > 0 {
				return
			}
		case <-deadline:
			t.Fatal("JDT LS published no diagnostics for a file with a type error")
		}
	}
}
