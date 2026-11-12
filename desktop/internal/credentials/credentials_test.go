package credentials

import (
	"context"
	"errors"
	"maps"
	"os"
	"slices"
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

// fakeLegacy is an older client's store: items in the order Items lists them, the
// secrets by service and key, and the refusals Read meets. reads counts the secrets read,
// and onRead runs before each read, as a prompt the user takes a while to answer.
type fakeLegacy struct {
	items   []LegacyItem
	secrets map[string]string
	refused map[string]bool
	listErr error
	reads   int
	onRead  func(LegacyItem)
}

func (l *fakeLegacy) Items() ([]LegacyItem, error) {
	return slices.Clone(l.items), l.listErr
}

func (l *fakeLegacy) Read(item LegacyItem) (string, error) {
	l.reads++
	if l.onRead != nil {
		l.onRead(item)
	}
	if l.refused[item.Service+"|"+item.Key] {
		return "", errors.New("keychain error -128")
	}
	v, ok := l.secrets[item.Service+"|"+item.Key]
	if !ok {
		return "", ErrNotFound
	}
	return v, nil
}

const (
	stablePrefix = "app.lithe.desktop.plugin-credentials."
	devPrefix    = "app.lithe.desktop.dev.plugin-credentials."
)

// oldItem is the older stable or development client's item of plugin and key, with its
// secret.
func (l *fakeLegacy) oldItem(prefix, plugin, key, secret string) {
	l.items = append(l.items, LegacyItem{Service: prefix + plugin, PluginID: plugin, Key: key})
	if l.secrets == nil {
		l.secrets = map[string]string{}
	}
	l.secrets[prefix+plugin+"|"+key] = secret
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

// The Viva client is a separate product: reading or deleting a plugin's secret never
// reads, copies or removes what an older client stored, which that client still uses.
func TestGetAndDeleteLeaveTheOlderClientsItemsAlone(t *testing.T) {
	backend := &memoryBackend{items: map[string]string{}}
	legacy := &fakeLegacy{}
	legacy.oldItem(stablePrefix, "p", "k", "old")
	store := New(backend, legacy)
	ctx := context.Background()
	if v, ok, err := store.Get(ctx, "p", "k"); err != nil || ok || v != "" {
		t.Fatalf("Get = %q %v %v, want nothing before an import", v, ok, err)
	}
	if err := store.Delete(ctx, "p", "k"); err != nil {
		t.Fatal(err)
	}
	if legacy.reads != 0 || len(backend.items) != 0 {
		t.Fatalf("the older store was read %d times and the new one holds %v", legacy.reads, backend.items)
	}
	if err := store.Delete(ctx, "p", "missing"); err != nil {
		t.Fatalf("deleting a missing credential: %v", err)
	}
	if items, _ := legacy.Items(); len(items) != 1 || legacy.secrets[stablePrefix+"p|k"] != "old" {
		t.Fatalf("the older client's items changed: %v %v", items, legacy.secrets)
	}
}

// An import the user asks for copies each older secret the Viva client has no value for,
// keeps the values it has, takes the stable client's value over the development one's,
// and counts the malformed and refused items without stopping or changing any of them.
func TestImportCopiesTheOlderSecretsAndKeepsTheNewerOnes(t *testing.T) {
	backend := &memoryBackend{items: map[string]string{Service("p") + "|b": "new-b"}}
	legacy := &fakeLegacy{refused: map[string]bool{stablePrefix + "r|k": true}}
	legacy.oldItem(stablePrefix, "p", "a", "old-a")
	legacy.oldItem(stablePrefix, "p", "b", "old-b")
	legacy.oldItem(stablePrefix, "p", "c", "stable-c")
	legacy.oldItem(stablePrefix, "q", "has space", "bad")
	legacy.oldItem(stablePrefix, "r", "k", "refused")
	legacy.oldItem(devPrefix, "p", "c", "dev-c")
	legacy.oldItem(devPrefix, "d", "k", "dev-only")
	before := maps.Clone(legacy.secrets)
	store := New(backend, legacy)
	if !store.CanImport() {
		t.Fatal("a store over an older client cannot import")
	}

	got, err := store.ImportLegacy(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if want := (ImportResult{Imported: 3, Kept: 1, Failed: 2}); got != want {
		t.Fatalf("ImportLegacy() = %+v, want %+v", got, want)
	}
	want := map[string]string{
		Service("p") + "|a": "old-a",
		Service("p") + "|b": "new-b",
		Service("p") + "|c": "stable-c",
		Service("d") + "|k": "dev-only",
	}
	if !maps.Equal(backend.items, want) {
		t.Fatalf("store after the import = %v, want %v", backend.items, want)
	}
	if !maps.Equal(legacy.secrets, before) {
		t.Fatalf("the older client's items changed: %v", legacy.secrets)
	}

	// Importing again copies nothing more and keeps what the first import copied.
	if got, err := store.ImportLegacy(context.Background()); err != nil || got.Imported != 0 || got.Kept != 4 {
		t.Fatalf("second ImportLegacy() = %+v %v, want everything kept", got, err)
	}
}

// A value a plugin stores while the platform waits for the user to allow reading the older
// item is newer than that item, so the import keeps it.
func TestImportKeepsAValueStoredWhileThePromptWasOpen(t *testing.T) {
	backend := &memoryBackend{items: map[string]string{}}
	legacy := &fakeLegacy{}
	legacy.oldItem(stablePrefix, "p", "k", "old")
	store := New(backend, legacy)
	legacy.onRead = func(LegacyItem) {
		if err := store.Set(context.Background(), "p", "k", "fresh"); err != nil {
			t.Error(err)
		}
	}
	got, err := store.ImportLegacy(context.Background())
	if err != nil || got != (ImportResult{Kept: 1}) {
		t.Fatalf("ImportLegacy() = %+v %v, want the item kept", got, err)
	}
	if v := backend.items[Service("p")+"|k"]; v != "fresh" {
		t.Fatalf("secret = %q, want the one the plugin stored", v)
	}
}

// Only failing to list the older items fails the import; without an older client there is
// nothing to import.
func TestImportFailsOnlyWhenTheOlderItemsCannotBeListed(t *testing.T) {
	listErr := errors.New("keychain error -25291")
	store := New(&memoryBackend{items: map[string]string{}}, &fakeLegacy{listErr: listErr})
	if _, err := store.ImportLegacy(context.Background()); !errors.Is(err, listErr) {
		t.Fatalf("ImportLegacy() error = %v, want the listing's", err)
	}
	none := New(&memoryBackend{items: map[string]string{}}, nil)
	if none.CanImport() {
		t.Fatal("a store without an older client can import")
	}
	if got, err := none.ImportLegacy(context.Background()); err != nil || got != (ImportResult{}) {
		t.Fatalf("ImportLegacy() without an older client = %+v %v", got, err)
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
