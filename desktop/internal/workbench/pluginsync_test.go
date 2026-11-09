package workbench

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginlsp"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
)

// openSyncDocument opens one real file through the workbench action and returns
// its document, without requiring a language server.
func openSyncDocument(t *testing.T, h *harness, root, name string) (*project, *document) {
	t.Helper()
	path := filepath.Join(root, name)
	if err := os.WriteFile(path, []byte("one\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	h.app.openFileAt(h.app.project, path, 1)
	h.settle()
	p := h.app.project
	d := p.docs.byPath(path)
	if d == nil {
		t.Fatal("the document did not open")
	}
	return p, d
}

func TestDocumentSyncDropsSupersededResult(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(t.TempDir())
	p, d := openSyncDocument(t, h, h.app.project.root, "A.java")
	d.sync.opened, d.sync.running = true, true
	d.sync.generation = 2

	// A result from the previous generation is ignored and leaves the current
	// state, including its in-flight flag, for the newer work.
	h.app.finishDocumentChange(p, d, 1, 0, nil, nil)
	if !d.sync.opened || !d.sync.running || d.sync.generation != 2 {
		t.Fatalf("a superseded result changed the state: %+v", d.sync)
	}

	// A result for another project is ignored as well.
	h.app.finishDocumentChange(&project{root: t.TempDir()}, d, 2, 0, nil, nil)
	if !d.sync.opened || !d.sync.running {
		t.Fatalf("a result for another project changed the state: %+v", d.sync)
	}
}

func TestReleasePluginDocumentsInvalidatesOnlyThatPlugin(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(t.TempDir())
	_, first := openSyncDocument(t, h, h.app.project.root, "A.java")
	_, second := openSyncDocument(t, h, h.app.project.root, "B.java")
	first.sync.opened, first.sync.pluginID, first.sync.uri = true, "java", "file:///A.java"
	second.sync.opened, second.sync.pluginID, second.sync.uri = true, "other", "file:///B.java"

	h.app.releasePluginDocuments("java")
	if first.sync.opened || first.sync.pluginID != "" || first.sync.uri != "" {
		t.Fatalf("the released document kept its sync: %+v", first.sync)
	}
	if !second.sync.opened || second.sync.pluginID != "other" {
		t.Fatalf("another plugin's document was released: %+v", second.sync)
	}
}

func TestDocumentSyncResetInvalidatesInFlightWork(t *testing.T) {
	var sync documentSync
	sync.opened, sync.running, sync.uri, sync.pluginID = true, true, "file:///A.java", "java"
	generation := sync.generation
	sync.reset()
	if sync.opened || sync.running || sync.uri != "" || sync.pluginID != "" {
		t.Fatalf("reset state = %+v", sync)
	}
	if sync.generation == generation {
		t.Fatal("reset did not invalidate the previous generation")
	}
}

type closeRecordKernel struct {
	closed []string
}

func (k *closeRecordKernel) SyncPluginDocument(_ context.Context, request core.PluginDocumentSyncRequest) (core.PluginDocumentSync, error) {
	return core.PluginDocumentSync{URI: request.URI, DocumentVersion: 1, Changed: true}, nil
}

func (k *closeRecordKernel) SavePluginDocument(context.Context, string, string, string) (bool, error) {
	return true, nil
}

func (k *closeRecordKernel) ClosePluginDocument(_ context.Context, _, uri string) error {
	k.closed = append(k.closed, uri)
	return nil
}

func TestLateOpenClosesDocumentItOpened(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(t.TempDir())
	p, d := openSyncDocument(t, h, h.app.project.root, "A.java")
	kernel := &closeRecordKernel{}
	tracker := pluginlsp.New(kernel, "session-1")
	if _, err := tracker.Open(context.Background(), pluginlsp.Document{URI: "file:///late.java", LanguageID: "java", Text: "x"}); err != nil {
		t.Fatal(err)
	}
	server := &pluginServer{session: &pluginservice.LanguageSession{PluginID: "java", Documents: tracker}, cancel: func() {}}
	h.app.pluginServers = map[string]*pluginServer{"java": server}
	// The document was closed while Open was in flight: the generation no
	// longer matches, so the successful Open must be undone.
	d.sync.generation = 2
	h.app.finishDocumentOpen(p, d, server, "java", 1, 0, "file:///late.java", nil, nil)
	h.settle()
	if len(kernel.closed) != 1 || kernel.closed[0] != "file:///late.java" {
		t.Fatalf("closed = %v, want the late document closed", kernel.closed)
	}
}

func TestReleasePluginInvalidatesOpeningDocument(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(t.TempDir())
	p, d := openSyncDocument(t, h, h.app.project.root, "A.java")
	d.languageID = "java"
	tracker := pluginlsp.New(&closeRecordKernel{}, "opening-session")
	server := &pluginServer{session: &pluginservice.LanguageSession{PluginID: "java", Documents: tracker}, cancel: func() {}}
	h.app.plugins = &pluginservice.Service{}
	h.app.pluginServers = map[string]*pluginServer{"java": server}
	h.app.pluginServerLanguages = map[string]string{"java": "java"}
	defer func() {
		h.app.plugins = nil
		h.app.pluginServers = nil
		h.app.pluginServerLanguages = nil
	}()
	h.app.startDocumentSync(p, d)
	// The window releases the plugin before applying the background Open result.
	// No sleeps: the window queue is only drained below.
	h.app.releasePluginDocuments("java")
	h.settle()
	if d.sync.opened || d.sync.running {
		t.Fatal("a late Open restored synchronization for the released plugin")
	}
}
