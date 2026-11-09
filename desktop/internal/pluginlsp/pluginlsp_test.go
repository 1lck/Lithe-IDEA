package pluginlsp

import (
	"context"
	"encoding/json"
	"errors"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// fakeKernel records what the tracker asked Core to do.
type fakeKernel struct {
	// resolvedURI is what Core reports as the document identity; empty means the
	// requested one.
	resolvedURI string
	version     int64
	syncErr     error
	saveSent    bool
	saveErr     error
	closeErr    error
	requests    []core.PluginDocumentSyncRequest
	saves       []string
	closed      []string
}

func (k *fakeKernel) SyncPluginDocument(_ context.Context, request core.PluginDocumentSyncRequest) (core.PluginDocumentSync, error) {
	k.requests = append(k.requests, request)
	if k.syncErr != nil {
		return core.PluginDocumentSync{}, k.syncErr
	}
	k.version++
	identity := request.URI
	if k.resolvedURI != "" {
		identity = k.resolvedURI
	}
	return core.PluginDocumentSync{DocumentVersion: k.version, Changed: true, URI: identity}, nil
}

func (k *fakeKernel) SavePluginDocument(_ context.Context, _ string, uri, text string) (bool, error) {
	if k.saveErr != nil {
		return false, k.saveErr
	}
	k.saves = append(k.saves, uri+"="+text)
	return k.saveSent, nil
}

func (k *fakeKernel) ClosePluginDocument(_ context.Context, _ string, uri string) error {
	if k.closeErr != nil {
		return k.closeErr
	}
	k.closed = append(k.closed, uri)
	return nil
}

const documentURI = "file:///workspace/A.java"

func TestOpenSendsTheWholeTextAndRecordsTheVersion(t *testing.T) {
	kernel := &fakeKernel{}
	tracker := New(kernel, "session-1")
	identity, err := tracker.Open(context.Background(), Document{
		URI:        documentURI,
		LanguageID: "java",
		Text:       "class A {}",
	})
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	if identity != documentURI {
		t.Fatalf("identity = %q", identity)
	}
	if len(kernel.requests) != 1 {
		t.Fatalf("requests = %+v", kernel.requests)
	}
	request := kernel.requests[0]
	if request.SessionID != "session-1" || request.LanguageID != "java" || request.Text != "class A {}" {
		t.Fatalf("request = %+v", request)
	}
	if len(request.ContentChanges) != 0 {
		t.Fatalf("the opening request carried changes: %+v", request.ContentChanges)
	}
	version, open := tracker.Version(documentURI)
	if !open || version != 1 {
		t.Fatalf("version = %d, open = %v", version, open)
	}
}

func TestOpenReKeysToTheResolvedIdentity(t *testing.T) {
	kernel := &fakeKernel{resolvedURI: "file:///workspace/a.java"}
	tracker := New(kernel, "session-1")
	identity, err := tracker.Open(context.Background(), Document{URI: documentURI, LanguageID: "java", Text: ""})
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	if identity != "file:///workspace/a.java" {
		t.Fatalf("identity = %q", identity)
	}
	if tracker.IsOpen(documentURI) {
		t.Fatal("the requested URI is still a key")
	}
	if !tracker.IsOpen(identity) {
		t.Fatal("the resolved URI is not a key")
	}
}

func TestChangeAdvancesTheVersion(t *testing.T) {
	kernel := &fakeKernel{}
	tracker := New(kernel, "session-1")
	identity, err := tracker.Open(context.Background(), Document{URI: documentURI, LanguageID: "java", Text: "a"})
	if err != nil {
		t.Fatal(err)
	}
	changes := []core.PluginTextChange{{Text: "b"}}
	if err := tracker.Change(context.Background(), identity, changes); err != nil {
		t.Fatalf("change: %v", err)
	}
	last := kernel.requests[len(kernel.requests)-1]
	if len(last.ContentChanges) != 1 || last.ContentChanges[0].Text != "b" {
		t.Fatalf("changes = %+v", last.ContentChanges)
	}
	// A change carries no full text: the whole document stays off the wire.
	if last.Text != "" {
		t.Fatalf("the change resent the text: %q", last.Text)
	}
	if last.LanguageID != "java" {
		t.Fatalf("language = %q", last.LanguageID)
	}
	version, _ := tracker.Version(identity)
	if version != 2 {
		t.Fatalf("version = %d", version)
	}
}

func TestChangeRefusesADocumentThatWasNeverOpened(t *testing.T) {
	tracker := New(&fakeKernel{}, "session-1")
	err := tracker.Change(context.Background(), documentURI, []core.PluginTextChange{{Text: "x"}})
	if !errors.Is(err, ErrNotOpen) {
		t.Fatalf("err = %v", err)
	}
}

func TestSaveReportsWhatCoreDid(t *testing.T) {
	kernel := &fakeKernel{saveSent: true}
	tracker := New(kernel, "session-1")
	identity, err := tracker.Open(context.Background(), Document{URI: documentURI, LanguageID: "java", Text: "a"})
	if err != nil {
		t.Fatal(err)
	}
	sent, err := tracker.Save(context.Background(), identity, "a")
	if err != nil || !sent {
		t.Fatalf("sent = %v, err = %v", sent, err)
	}
	if len(kernel.saves) != 1 || kernel.saves[0] != identity+"=a" {
		t.Fatalf("saves = %v", kernel.saves)
	}
	// A save the session had nothing to do for is not an error.
	kernel.saveSent = false
	if sent, err := tracker.Save(context.Background(), identity, "a"); err != nil || sent {
		t.Fatalf("sent = %v, err = %v", sent, err)
	}
}

func TestSaveRefusesADocumentThatWasNeverOpened(t *testing.T) {
	tracker := New(&fakeKernel{}, "session-1")
	if _, err := tracker.Save(context.Background(), documentURI, "x"); !errors.Is(err, ErrNotOpen) {
		t.Fatalf("err = %v", err)
	}
}

func TestCloseForgetsTheDocument(t *testing.T) {
	kernel := &fakeKernel{}
	tracker := New(kernel, "session-1")
	identity, err := tracker.Open(context.Background(), Document{URI: documentURI, LanguageID: "java", Text: "a"})
	if err != nil {
		t.Fatal(err)
	}
	if err := tracker.Close(context.Background(), identity); err != nil {
		t.Fatalf("close: %v", err)
	}
	if len(kernel.closed) != 1 || kernel.closed[0] != identity {
		t.Fatalf("closed = %v", kernel.closed)
	}
	if tracker.IsOpen(identity) {
		t.Fatal("the document is still open")
	}
	// A change after close is refused instead of reaching a document the server
	// no longer holds.
	if err := tracker.Change(context.Background(), identity, []core.PluginTextChange{{Text: "x"}}); !errors.Is(err, ErrNotOpen) {
		t.Fatalf("err = %v", err)
	}
	// Closing twice is not an error.
	if err := tracker.Close(context.Background(), identity); err != nil {
		t.Fatalf("second close: %v", err)
	}
}

func TestOpenTwiceReplacesTheVersion(t *testing.T) {
	kernel := &fakeKernel{}
	tracker := New(kernel, "session-1")
	if _, err := tracker.Open(context.Background(), Document{URI: documentURI, LanguageID: "java", Text: "a"}); err != nil {
		t.Fatal(err)
	}
	identity, err := tracker.Open(context.Background(), Document{URI: documentURI, LanguageID: "java", Text: "b"})
	if err != nil {
		t.Fatalf("second open: %v", err)
	}
	if version, _ := tracker.Version(identity); version != 2 {
		t.Fatalf("version = %d", version)
	}
	if last := kernel.requests[len(kernel.requests)-1]; last.Text != "b" {
		t.Fatalf("text = %q", last.Text)
	}
}

func TestTrackerRefusesIncompleteSetup(t *testing.T) {
	if _, err := New(nil, "session-1").Open(context.Background(), Document{URI: documentURI}); err == nil {
		t.Fatal("a tracker without a kernel opened a document")
	}
	if _, err := New(&fakeKernel{}, "").Open(context.Background(), Document{URI: documentURI}); !errors.Is(err, ErrNoSession) {
		t.Fatalf("err = %v", err)
	}
	tracker := New(&fakeKernel{}, "session-1")
	if _, err := tracker.Open(context.Background(), Document{}); !errors.Is(err, ErrNotOpen) {
		t.Fatalf("err = %v", err)
	}
}

func TestTrackerPropagatesCoreErrors(t *testing.T) {
	refusal := errors.New("documentNotSynchronized")
	kernel := &fakeKernel{syncErr: refusal}
	tracker := New(kernel, "session-1")
	if _, err := tracker.Open(context.Background(), Document{URI: documentURI, Text: "a"}); !errors.Is(err, refusal) {
		t.Fatalf("err = %v", err)
	}
	// A refused open leaves nothing behind.
	if tracker.IsOpen(documentURI) {
		t.Fatal("a refused open recorded the document")
	}
}

func TestChangeCarriesRangesAsGiven(t *testing.T) {
	kernel := &fakeKernel{}
	tracker := New(kernel, "session-1")
	identity, err := tracker.Open(context.Background(), Document{URI: documentURI, LanguageID: "java", Text: "abc"})
	if err != nil {
		t.Fatal(err)
	}
	changes := []core.PluginTextChange{{
		Range: &core.PluginDocumentRange{
			Start: core.PluginDocumentPosition{Line: 1, Character: 1},
			End:   core.PluginDocumentPosition{Line: 1, Character: 2},
		},
		Text: "x",
	}}
	if err := tracker.Change(context.Background(), identity, changes); err != nil {
		t.Fatalf("change: %v", err)
	}
	last := kernel.requests[len(kernel.requests)-1]
	encoded, err := json.Marshal(last.ContentChanges)
	if err != nil {
		t.Fatal(err)
	}
	want := `[{"range":{"start":{"line":1,"character":1},"end":{"line":1,"character":2}},"text":"x"}]`
	if string(encoded) != want {
		t.Fatalf("changes = %s", encoded)
	}
}
