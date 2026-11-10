package credentials

import (
	"context"
	"errors"
	"os"
	"strings"
	"testing"
)

type memoryBackend struct {
	items   map[string]string
	setFail error
}

func (m *memoryBackend) Get(service, account string) (string, error) {
	if v, ok := m.items[service+"|"+account]; ok {
		return v, nil
	}
	return "", ErrNotFound
}

func (m *memoryBackend) Set(service, account, secret string) error {
	if m.setFail != nil {
		return m.setFail
	}
	m.items[service+"|"+account] = secret
	return nil
}

func (m *memoryBackend) Delete(service, account string) error {
	if _, ok := m.items[service+"|"+account]; !ok {
		return ErrNotFound
	}
	delete(m.items, service+"|"+account)
	return nil
}

type fakeLegacy struct {
	items   map[string]string
	deleted []string
}

func (l *fakeLegacy) Read(pluginID, key string) (string, bool) {
	v, ok := l.items[pluginID+"|"+key]
	return v, ok
}

func (l *fakeLegacy) Delete(pluginID, key string) {
	delete(l.items, pluginID+"|"+key)
	l.deleted = append(l.deleted, pluginID+"|"+key)
}

func TestPluginsAreIsolatedByService(t *testing.T) {
	backend := &memoryBackend{items: map[string]string{}}
	store := New(backend, nil)
	ctx := context.Background()
	if err := store.Set(ctx, "a.plugin", "token", "one"); err != nil {
		t.Fatal(err)
	}
	if _, ok, _ := store.Get(ctx, "b.plugin", "token"); ok {
		t.Fatal("another plugin read the secret")
	}
	if v, ok, err := store.Get(ctx, "a.plugin", "token"); err != nil || !ok || v != "one" {
		t.Fatalf("Get = %q %v %v", v, ok, err)
	}
	if _, ok := backend.items[ServicePrefix+".a.plugin|token"]; !ok {
		t.Fatalf("unexpected service names: %v", backend.items)
	}
}

func TestLegacyValueMigratesAndStaysForTheOldClient(t *testing.T) {
	backend := &memoryBackend{items: map[string]string{}}
	legacy := &fakeLegacy{items: map[string]string{"p|k": "old"}}
	store := New(backend, legacy)
	ctx := context.Background()
	v, ok, err := store.Get(ctx, "p", "k")
	if err != nil || !ok || v != "old" {
		t.Fatalf("Get = %q %v %v", v, ok, err)
	}
	if backend.items[Service("p")+"|k"] != "old" {
		t.Fatal("the legacy value was not copied to the new location")
	}
	if len(legacy.deleted) != 0 {
		t.Fatal("migration removed the old item, which the old client may still use")
	}
	// A new value wins over the legacy one.
	if err := store.Set(ctx, "p", "k", "new"); err != nil {
		t.Fatal(err)
	}
	if v, _, _ := store.Get(ctx, "p", "k"); v != "new" {
		t.Fatalf("Get = %q, want new", v)
	}
}

func TestFailedMigrationCopyStillReturnsTheOldValue(t *testing.T) {
	backend := &memoryBackend{items: map[string]string{}, setFail: errors.New("locked")}
	store := New(backend, &fakeLegacy{items: map[string]string{"p|k": "old"}})
	if v, ok, err := store.Get(context.Background(), "p", "k"); err != nil || !ok || v != "old" {
		t.Fatalf("Get = %q %v %v", v, ok, err)
	}
}

func TestDeleteRemovesBothLocationsAndSucceedsWhenMissing(t *testing.T) {
	backend := &memoryBackend{items: map[string]string{}}
	legacy := &fakeLegacy{items: map[string]string{"p|k": "old"}}
	store := New(backend, legacy)
	ctx := context.Background()
	if err := store.Delete(ctx, "p", "k"); err != nil {
		t.Fatal(err)
	}
	if _, ok, _ := store.Get(ctx, "p", "k"); ok {
		t.Fatal("a deleted credential came back through migration")
	}
	if err := store.Delete(ctx, "p", "missing"); err != nil {
		t.Fatalf("deleting a missing credential: %v", err)
	}
}

func TestValidation(t *testing.T) {
	store := New(&memoryBackend{items: map[string]string{}}, nil)
	ctx := context.Background()
	for _, key := range []string{"", "has space", "sl/ash", strings.Repeat("a", 129)} {
		if err := store.Set(ctx, "p", key, "x"); !errors.Is(err, ErrInvalid) {
			t.Errorf("key %q: %v", key, err)
		}
	}
	if err := store.Set(ctx, "p", "k", strings.Repeat("a", MaxSecretBytes+1)); !errors.Is(err, ErrInvalid) {
		t.Errorf("oversize secret: %v", err)
	}
	if err := store.Set(ctx, "", "k", "x"); !errors.Is(err, ErrInvalid) {
		t.Errorf("empty plugin: %v", err)
	}
}

func TestCancelledContextDoesNotWaitForTheBackend(t *testing.T) {
	block := make(chan struct{})
	defer close(block)
	store := New(blockingBackend{block}, nil)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, _, err := store.Get(ctx, "p", "k"); !errors.Is(err, context.Canceled) {
		t.Fatalf("Get = %v", err)
	}
}

type blockingBackend struct{ block chan struct{} }

func (b blockingBackend) Get(string, string) (string, error) { <-b.block; return "", ErrNotFound }
func (b blockingBackend) Set(string, string, string) error   { <-b.block; return nil }
func (b blockingBackend) Delete(string, string) error        { <-b.block; return nil }

// TestPlatformStoreRoundTrip talks to the real secret store under a throwaway
// plugin ID. It is opt-in because an unsigned test binary can make the macOS
// Keychain ask for the user's password.
func TestPlatformStoreRoundTrip(t *testing.T) {
	if os.Getenv("LITHE_TEST_KEYCHAIN") != "1" {
		t.Skip("set LITHE_TEST_KEYCHAIN=1 to use the real platform secret store")
	}
	store := New(platformBackend(), nil)
	ctx := context.Background()
	const plugin = "lithe.test.credentials.roundtrip"
	t.Cleanup(func() { _ = store.Delete(ctx, plugin, "k") })
	if err := store.Set(ctx, plugin, "k", "secret-value"); err != nil {
		t.Fatal(err)
	}
	if v, ok, err := store.Get(ctx, plugin, "k"); err != nil || !ok || v != "secret-value" {
		t.Fatalf("Get = %q %v %v", v, ok, err)
	}
	if err := store.Delete(ctx, plugin, "k"); err != nil {
		t.Fatal(err)
	}
	if _, ok, _ := store.Get(ctx, plugin, "k"); ok {
		t.Fatal("still present after delete")
	}
}
