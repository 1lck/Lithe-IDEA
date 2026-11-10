package pluginservice

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"sync"
)

// ErrContextExpired reports a workspace context that is closed or whose
// generation was replaced.
var ErrContextExpired = errors.New("workspace context is closed or replaced")

// ContextRef is the {contextID, generation} reference a plugin names a context with.
type ContextRef struct {
	ContextID  string `json:"contextID"`
	Generation uint64 `json:"generation"`
}

// WorkspaceContext is one open workspace in this window.
type WorkspaceContext struct {
	ContextRef
	// Name is the workspace's display name.
	Name string
	// Path is the local root folder.
	Path string
}

// WorkspaceContexts keeps the contexts plugin backends see.
//
// A context lives as long as the window shows that workspace: closing the
// project closes it, and opening another project opens a new one with a new ID,
// so state a backend keyed by the ID never carries over to a different
// workspace. The client has one window, so there is normally at most one.
type WorkspaceContexts struct {
	mu       sync.Mutex
	revision uint64
	byPath   map[string]*WorkspaceContext
	secret   []byte
	// stateRoot holds the plugin storage; per-workspace state lives below it.
	stateRoot string
	onChange  func()
	// onClosed hears the ID of every context that ends, so what was made for it can go too.
	onClosed func(contextID string)
}

// newWorkspaceContexts loads or creates the host secret that keys root IDs. The
// secret is stored beside the plugin state, never in a package or the app bundle.
func newWorkspaceContexts(stateRoot string) *WorkspaceContexts {
	contexts := &WorkspaceContexts{byPath: make(map[string]*WorkspaceContext), stateRoot: stateRoot}
	path := filepath.Join(stateRoot, "host-secret")
	if data, err := os.ReadFile(path); err == nil && len(data) >= 32 {
		contexts.secret = data
		return contexts
	}
	secret := make([]byte, 32)
	if _, err := rand.Read(secret); err != nil {
		// Without randomness a fixed secret would make root IDs guessable.
		panic("pluginservice: no randomness for the host secret: " + err.Error())
	}
	contexts.secret = secret
	if os.MkdirAll(stateRoot, 0o700) == nil {
		_ = os.WriteFile(path, secret, 0o600)
	}
	return contexts
}

// SetObserver installs the function called after the set of contexts changed.
// It runs without the lock held.
func (c *WorkspaceContexts) SetObserver(onChange func()) {
	c.mu.Lock()
	c.onChange = onChange
	c.mu.Unlock()
}

// SetClosedObserver installs the function called with the ID of each context that
// closes. It runs without the lock held.
func (c *WorkspaceContexts) SetClosedObserver(onClosed func(contextID string)) {
	c.mu.Lock()
	c.onClosed = onClosed
	c.mu.Unlock()
}

// Open returns the context of a workspace root, creating it when the workspace
// is not open yet.
func (c *WorkspaceContexts) Open(path string) WorkspaceContext {
	path = filepath.Clean(path)
	c.mu.Lock()
	if existing, ok := c.byPath[path]; ok {
		value := *existing
		c.mu.Unlock()
		return value
	}
	id := make([]byte, 6)
	_, _ = rand.Read(id)
	created := &WorkspaceContext{
		ContextRef: ContextRef{ContextID: "w-" + hex.EncodeToString(id), Generation: 1},
		Name:       filepath.Base(path),
		Path:       path,
	}
	c.byPath[path] = created
	c.revision++
	observer := c.onChange
	value := *created
	c.mu.Unlock()
	if observer != nil {
		observer()
	}
	return value
}

// Close ends the context of a workspace root.
func (c *WorkspaceContexts) Close(path string) {
	path = filepath.Clean(path)
	c.mu.Lock()
	closing, ok := c.byPath[path]
	if !ok {
		c.mu.Unlock()
		return
	}
	delete(c.byPath, path)
	c.revision++
	observer, closed := c.onChange, c.onClosed
	id := closing.ContextID
	c.mu.Unlock()
	if closed != nil {
		closed(id)
	}
	if observer != nil {
		observer()
	}
}

// CloseAll ends every context.
func (c *WorkspaceContexts) CloseAll() {
	c.mu.Lock()
	if len(c.byPath) == 0 {
		c.mu.Unlock()
		return
	}
	ids := make([]string, 0, len(c.byPath))
	for _, closing := range c.byPath {
		ids = append(ids, closing.ContextID)
	}
	c.byPath = make(map[string]*WorkspaceContext)
	c.revision++
	observer, closed := c.onChange, c.onClosed
	c.mu.Unlock()
	if closed != nil {
		for _, id := range ids {
			closed(id)
		}
	}
	if observer != nil {
		observer()
	}
}

// ByPath returns the open context of a workspace root.
func (c *WorkspaceContexts) ByPath(path string) (WorkspaceContext, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if existing, ok := c.byPath[filepath.Clean(path)]; ok {
		return *existing, true
	}
	return WorkspaceContext{}, false
}

// Lookup resolves a reference, refusing a closed context or an old generation.
func (c *WorkspaceContexts) Lookup(ref ContextRef) (WorkspaceContext, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	for _, existing := range c.byPath {
		if existing.ContextID == ref.ContextID {
			if existing.Generation != ref.Generation {
				return WorkspaceContext{}, ErrContextExpired
			}
			return *existing, nil
		}
	}
	return WorkspaceContext{}, ErrContextExpired
}

// List returns the revision and every open context, ordered by ID.
func (c *WorkspaceContexts) List() (uint64, []WorkspaceContext) {
	c.mu.Lock()
	defer c.mu.Unlock()
	contexts := make([]WorkspaceContext, 0, len(c.byPath))
	for _, existing := range c.byPath {
		contexts = append(contexts, *existing)
	}
	sort.Slice(contexts, func(i, j int) bool { return contexts[i].ContextID < contexts[j].ContextID })
	return c.revision, contexts
}

// Revision is the counter didChangeContexts reports.
func (c *WorkspaceContexts) Revision() uint64 {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.revision
}

// RootID identifies one root folder for one plugin. It is keyed with the host
// secret, so two plugins see different IDs for the same folder and an ID cannot
// be computed from a guessed path.
func (c *WorkspaceContexts) RootID(pluginID, path string) string {
	mac := hmac.New(sha256.New, c.secret)
	mac.Write([]byte(pluginID))
	mac.Write([]byte{0})
	mac.Write([]byte(filepath.Clean(path)))
	return "r" + hex.EncodeToString(mac.Sum(nil))[:16]
}

// WorkspaceKey is the name of a workspace's directories below a plugin's state.
// It is a digest, so the path is not revealed and the name is one path component.
func WorkspaceKey(path string) string {
	sum := sha256.Sum256([]byte(filepath.Clean(path)))
	return hex.EncodeToString(sum[:])[:24]
}
