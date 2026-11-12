// Package pluginlsp keeps the editor's open documents in step with one language
// server session.
//
// Core owns the server process and the protocol; this package owns the small piece
// of state that makes the contract's document rules true: a document is opened once
// at version 1, every later change carries a higher version, and a document that was
// never opened is not changed. Getting that wrong is what makes a server answer with
// stale positions.
//
// The tracker holds no text of its own beyond what it needs to open a document: a
// change is sent as the edits themselves, which keeps a large document off the wire
// for every keystroke.
package pluginlsp

import (
	"context"
	"errors"
	"fmt"
	"sync"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

var (
	// ErrNoSession reports work asked of a tracker with no session.
	ErrNoSession = errors.New("plugin language session is not open")
	// ErrNotOpen reports a change, save or close for a document that was never
	// opened in this session.
	ErrNotOpen = errors.New("plugin document is not open")
)

// Kernel is the part of the Core client this package uses. *core.Client
// satisfies it.
type Kernel interface {
	SyncPluginDocument(ctx context.Context, request core.PluginDocumentSyncRequest) (core.PluginDocumentSync, error)
	SavePluginDocument(ctx context.Context, session, uri, text string) (sent bool, err error)
	ClosePluginDocument(ctx context.Context, session, uri string) error
}

// Document is one document the editor wants a server to know.
type Document struct {
	// URI is the document identity, which Core resolves to the session's own.
	URI string
	// LanguageID is the language the document is in.
	LanguageID string
	// Text is the whole document, read once when it is opened.
	Text string
}

// entry is what the tracker remembers about one open document.
type entry struct {
	languageID string
	// version is the version the session holds, as Core reported it.
	version int64
}

// Tracker keeps one session's documents.
type Tracker struct {
	mu      sync.Mutex
	kernel  Kernel
	session string
	open    map[string]entry
}

// New returns a tracker for one session.
func New(kernel Kernel, session string) *Tracker {
	return &Tracker{kernel: kernel, session: session, open: make(map[string]entry)}
}

// Open opens a document in the session and returns the identity Core resolved.
//
// Opening a document that is already open sends its full text again, which Core
// treats as a replacement rather than a new document.
func (t *Tracker) Open(ctx context.Context, document Document) (string, error) {
	if err := t.check(document.URI); err != nil {
		return "", err
	}
	synced, err := t.kernel.SyncPluginDocument(ctx, core.PluginDocumentSyncRequest{
		SessionID:  t.session,
		URI:        document.URI,
		LanguageID: document.LanguageID,
		Text:       document.Text,
	})
	if err != nil {
		return "", err
	}
	identity := document.URI
	if synced.URI != "" {
		identity = synced.URI
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	if identity != document.URI {
		// Core resolved the identity to its own spelling; the requested one is no
		// longer a key anyone should use.
		delete(t.open, document.URI)
	}
	t.open[identity] = entry{languageID: document.LanguageID, version: synced.DocumentVersion}
	return identity, nil
}

// Change applies edits to an open document.
//
// The changes are LSP content changes in the order they happened: each range is
// relative to the result of the previous one. A document this tracker never opened
// is refused here rather than sent, because Core would answer with a version error
// that reads like a server problem.
func (t *Tracker) Change(ctx context.Context, uri string, changes []core.PluginTextChange) error {
	if err := t.check(uri); err != nil {
		return err
	}
	t.mu.Lock()
	held, ok := t.open[uri]
	t.mu.Unlock()
	if !ok {
		return fmt.Errorf("%w: %s", ErrNotOpen, uri)
	}
	synced, err := t.kernel.SyncPluginDocument(ctx, core.PluginDocumentSyncRequest{
		SessionID:      t.session,
		URI:            uri,
		LanguageID:     held.languageID,
		ContentChanges: changes,
	})
	if err != nil {
		return err
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	if current, still := t.open[uri]; still {
		// A concurrent close must not be resurrected by a late answer.
		current.version = synced.DocumentVersion
		t.open[uri] = current
	}
	return nil
}

// Save reports a confirmed disk save with the exact text that was written.
//
// sent is false when the session holds no ready copy or newer edits superseded the
// snapshot, which is not an error: the server simply had nothing to do.
func (t *Tracker) Save(ctx context.Context, uri, text string) (bool, error) {
	if err := t.check(uri); err != nil {
		return false, err
	}
	t.mu.Lock()
	_, ok := t.open[uri]
	t.mu.Unlock()
	if !ok {
		return false, fmt.Errorf("%w: %s", ErrNotOpen, uri)
	}
	return t.kernel.SavePluginDocument(ctx, t.session, uri, text)
}

// Close closes a document and forgets it, so a later change is refused instead of
// reaching a document the server no longer holds.
func (t *Tracker) Close(ctx context.Context, uri string) error {
	if err := t.check(uri); err != nil {
		return err
	}
	t.mu.Lock()
	_, ok := t.open[uri]
	t.mu.Unlock()
	if !ok {
		return nil
	}
	if err := t.kernel.ClosePluginDocument(ctx, t.session, uri); err != nil {
		return err
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	delete(t.open, uri)
	return nil
}

// Version reports the version the session holds for a document.
func (t *Tracker) Version(uri string) (int64, bool) {
	t.mu.Lock()
	defer t.mu.Unlock()
	held, ok := t.open[uri]
	return held.version, ok
}

// Open reports whether a document is open in this session.
func (t *Tracker) IsOpen(uri string) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	_, ok := t.open[uri]
	return ok
}

func (t *Tracker) check(uri string) error {
	if t == nil || t.kernel == nil {
		return errors.New("pluginlsp: no kernel")
	}
	if t.session == "" {
		return ErrNoSession
	}
	if uri == "" {
		return fmt.Errorf("%w: the document has no URI", ErrNotOpen)
	}
	return nil
}
