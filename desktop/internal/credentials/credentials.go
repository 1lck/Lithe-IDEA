// Package credentials keeps plugin secrets in the platform secret store.
//
// Core owns the rules of the plugin contract (key alphabet, size limits,
// permissions); this package only does the I/O. It never logs a key or a secret
// and never writes either to a plain file.
//
// Each plugin gets a secret-store service of its own, so one query removes
// everything a plugin stored and no key a plugin chooses can reach another
// plugin's items. The contract names the plugin ID as the namespace, not the
// workspace, because credentials/get carries no context; a plugin that wants a
// per-project secret puts the project in the key.
package credentials

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"
)

// ServicePrefix is the secret-store service of the Viva client. The plugin ID is
// appended per plugin. It differs from the older clients' prefix on purpose: the
// two can be installed side by side and must not overwrite each other.
const ServicePrefix = "app.lithe.viva.plugin-credentials"

const (
	// MaxKeyBytes and MaxSecretBytes are the contract's limits.
	MaxKeyBytes    = 128
	MaxSecretBytes = 16 * 1024
)

var (
	// ErrNotFound reports that a backend holds nothing for the item.
	ErrNotFound = errors.New("credential not found")
	// ErrTooLarge reports a secret the platform store cannot hold (Windows
	// Credential Manager caps a blob at 2560 bytes).
	ErrTooLarge = errors.New("credential is too large for the platform secret store")
	// ErrInvalid reports a malformed plugin ID, key or secret.
	ErrInvalid = errors.New("invalid credential request")
)

// Backend is one platform secret store. Errors other than ErrNotFound and
// ErrTooLarge are returned as they are and never contain the secret.
type Backend interface {
	Get(service, account string) (string, error)
	Set(service, account, secret string) error
	Delete(service, account string) error
}

// Legacy is the secret store an older client kept plugin secrets in. The Viva client is
// a separate product that can be installed beside the older one, so it never reads that
// store on its own and never changes it: the user imports from it once, on request, and
// the older client keeps every item it had.
type Legacy interface {
	// Items lists the items the older client stored, in the order they are imported. It
	// reads no secret and never raises a prompt.
	Items() ([]LegacyItem, error)
	// Read returns the secret of one item. The platform may ask the user to allow it,
	// since one app is reading what another wrote, and a refusal is an error.
	Read(item LegacyItem) (string, error)
}

// LegacyItem is one secret an older client stored: its secret-store service, and the
// plugin and key it belongs to.
type LegacyItem struct {
	Service, PluginID, Key string
}

// ImportResult counts what an import did: Imported secrets were copied to the Viva
// client's store, Kept ones were left because the Viva client already had a value for
// the plugin and key, and Failed ones could not be read or stored.
type ImportResult struct {
	Imported, Kept, Failed int
}

// Store is the credential service of one client.
type Store struct {
	backend Backend
	legacy  Legacy
	mu      sync.Mutex
}

// New returns a store over a backend. legacy may be nil.
func New(backend Backend, legacy Legacy) *Store {
	return &Store{backend: backend, legacy: legacy}
}

// Default returns the store of the running platform.
func Default() *Store {
	return New(platformBackend(), platformLegacy())
}

// Service is the secret-store service name of one plugin.
func Service(pluginID string) string { return ServicePrefix + "." + pluginID }

func validate(pluginID, key string) error {
	if pluginID == "" || len(pluginID) > 128 || strings.ContainsAny(pluginID, "\x00\r\n") {
		return fmt.Errorf("%w: plugin ID", ErrInvalid)
	}
	if key == "" || len(key) > MaxKeyBytes {
		return fmt.Errorf("%w: key", ErrInvalid)
	}
	for i := 0; i < len(key); i++ {
		c := key[i]
		switch {
		case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9':
		case c == '.' || c == '_' || c == ':' || c == '-':
		default:
			return fmt.Errorf("%w: key", ErrInvalid)
		}
	}
	return nil
}

// run bounds a blocking platform call by the request's context. The call itself
// cannot be interrupted, so it finishes in the background and its result is dropped.
func run[T any](ctx context.Context, call func() (T, error)) (T, error) {
	type outcome struct {
		value T
		err   error
	}
	done := make(chan outcome, 1)
	go func() {
		value, err := call()
		done <- outcome{value, err}
	}()
	select {
	case result := <-done:
		return result.value, result.err
	case <-ctx.Done():
		var zero T
		return zero, ctx.Err()
	}
}

// Get returns a plugin's secret. It reads only the Viva client's store: what an older
// client stored arrives only through ImportLegacy.
func (s *Store) Get(ctx context.Context, pluginID, key string) (string, bool, error) {
	if err := validate(pluginID, key); err != nil {
		return "", false, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	secret, err := run(ctx, func() (string, error) { return s.backend.Get(Service(pluginID), key) })
	switch {
	case err == nil:
		return secret, true, nil
	case errors.Is(err, ErrNotFound):
		return "", false, nil
	}
	return "", false, err
}

// Set stores a plugin's secret.
func (s *Store) Set(ctx context.Context, pluginID, key, secret string) error {
	if err := validate(pluginID, key); err != nil {
		return err
	}
	if len(secret) > MaxSecretBytes {
		return fmt.Errorf("%w: secret", ErrInvalid)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	_, err := run(ctx, func() (struct{}, error) { return struct{}{}, s.backend.Set(Service(pluginID), key, secret) })
	return err
}

// Delete removes a plugin's secret from the Viva client's store; an older client's item
// stays for that client. Deleting what is not there succeeds.
func (s *Store) Delete(ctx context.Context, pluginID, key string) error {
	if err := validate(pluginID, key); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	_, err := run(ctx, func() (struct{}, error) { return struct{}{}, s.backend.Delete(Service(pluginID), key) })
	if err != nil && !errors.Is(err, ErrNotFound) {
		return err
	}
	return nil
}

// CanImport says the platform has an older client whose plugin secrets ImportLegacy can
// copy.
func (s *Store) CanImport() bool { return s.legacy != nil }

// ImportLegacy copies the plugin secrets an older client stored into the Viva client's
// store, as the user asked once. A value the Viva client already has for the plugin and
// key wins and is kept, and the older client's items are never changed. An item that
// cannot be read, because the user refused the platform's prompt or it is malformed, is
// counted and the import goes on; only failing to list the items fails the import.
func (s *Store) ImportLegacy(ctx context.Context) (ImportResult, error) {
	var result ImportResult
	if s.legacy == nil {
		return result, nil
	}
	items, err := run(ctx, s.legacy.Items)
	if err != nil {
		return result, err
	}
	seen := map[[2]string]bool{}
	for _, item := range items {
		if err := ctx.Err(); err != nil {
			return result, err
		}
		id := [2]string{item.PluginID, item.Key}
		if seen[id] {
			continue
		}
		seen[id] = true
		if err := validate(item.PluginID, item.Key); err != nil {
			result.Failed++
			continue
		}
		switch imported, err := s.importItem(ctx, item); {
		case err != nil:
			if ctx.Err() != nil {
				return result, ctx.Err()
			}
			result.Failed++
		case imported:
			result.Imported++
		default:
			result.Kept++
		}
	}
	return result, nil
}

// importItem copies one older item unless the Viva client has a value for it, and says
// whether it did. The older secret is read without the lock, since the platform may wait
// for the user to answer its prompt, and the Viva client's store is checked again under
// the lock before the copy, so a value a plugin stored meanwhile is not overwritten.
func (s *Store) importItem(ctx context.Context, item LegacyItem) (bool, error) {
	if _, ok, err := s.Get(ctx, item.PluginID, item.Key); err != nil || ok {
		return false, err
	}
	secret, err := run(ctx, func() (string, error) { return s.legacy.Read(item) })
	if err != nil {
		return false, err
	}
	if len(secret) > MaxSecretBytes {
		return false, fmt.Errorf("%w: secret", ErrInvalid)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	service := Service(item.PluginID)
	switch _, err := run(ctx, func() (string, error) { return s.backend.Get(service, item.Key) }); {
	case err == nil:
		return false, nil
	case !errors.Is(err, ErrNotFound):
		return false, err
	}
	if _, err := run(ctx, func() (struct{}, error) { return struct{}{}, s.backend.Set(service, item.Key, secret) }); err != nil {
		return false, err
	}
	return true, nil
}
