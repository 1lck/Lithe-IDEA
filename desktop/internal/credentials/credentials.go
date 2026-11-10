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

// Legacy reads the secrets an older client stored for a plugin. It is read-only
// on purpose: the old and new clients can be installed side by side, so the new
// one must not remove what the old one still uses.
type Legacy interface {
	// Read returns the old value. A missing item and an unreadable one both
	// report ok=false: reading must never raise a password prompt.
	Read(pluginID, key string) (secret string, ok bool)
	// Delete removes the old item and is called only after the user asked the
	// plugin to delete the credential.
	Delete(pluginID, key string)
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

// Get returns a plugin's secret. When the new location has none and an older
// client stored one, the old value is copied to the new location and returned;
// the old item is left in place.
func (s *Store) Get(ctx context.Context, pluginID, key string) (string, bool, error) {
	if err := validate(pluginID, key); err != nil {
		return "", false, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	service := Service(pluginID)
	secret, err := run(ctx, func() (string, error) { return s.backend.Get(service, key) })
	if err == nil {
		return secret, true, nil
	}
	if !errors.Is(err, ErrNotFound) {
		return "", false, err
	}
	if s.legacy == nil {
		return "", false, nil
	}
	old, ok := s.legacy.Read(pluginID, key)
	if !ok {
		return "", false, nil
	}
	// The value is usable even when the new store cannot take it right now, so a
	// failed copy is not a failed read; the next read tries again.
	if _, err := run(ctx, func() (struct{}, error) { return struct{}{}, s.backend.Set(service, key, old) }); err != nil && ctx.Err() != nil {
		return "", false, ctx.Err()
	}
	return old, true, nil
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

// Delete removes a plugin's secret from the new location and from the older
// client's one, so a deleted value cannot come back through migration. Deleting
// what is not there succeeds.
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
	if s.legacy != nil {
		s.legacy.Delete(pluginID, key)
	}
	return nil
}
