package workbench

import (
	"maps"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/credentials"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

// mapSecrets is a secret store in memory, by service and account.
type mapSecrets map[string]string

func (m mapSecrets) Get(service, account string) (string, error) {
	v, ok := m[service+"|"+account]
	if !ok {
		return "", credentials.ErrNotFound
	}
	return v, nil
}

func (m mapSecrets) Set(service, account, secret string) error {
	m[service+"|"+account] = secret
	return nil
}

func (m mapSecrets) Delete(service, account string) error {
	delete(m, service+"|"+account)
	return nil
}

// earlierSecrets is an earlier client's store: its items and their secrets, by service and key.
type earlierSecrets struct {
	items   []credentials.LegacyItem
	secrets map[string]string
}

func (e *earlierSecrets) Items() ([]credentials.LegacyItem, error) { return e.items, nil }

func (e *earlierSecrets) Read(item credentials.LegacyItem) (string, error) {
	v, ok := e.secrets[item.Service+"|"+item.Key]
	if !ok {
		return "", credentials.ErrNotFound
	}
	return v, nil
}

// credentialHarness is a window whose plugin stack keeps its secrets in backend, over the
// earlier client's store legacy, nil for none.
func credentialHarness(t *testing.T, backend mapSecrets, legacy credentials.Legacy) *harness {
	t.Helper()
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	service, err := pluginservice.Open(core.NewClient(), store.At(t.TempDir()), t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	service.Credentials = credentials.New(backend, legacy)
	h.app.plugins = service
	h.open(t.TempDir())
	return h
}

// openGearMenu opens the settings button's menu.
func (h *harness) openGearMenu() {
	h.t.Helper()
	gear := center(h.button(itemTitleSettings))
	if err := h.driver.Click(gear.X, gear.Y); err != nil {
		h.t.Fatal(err)
	}
	h.settle()
}

// The settings menu imports an earlier client's plugin secrets only once the user confirms,
// copies the one the window has no value for, keeps the one it has, leaves the earlier
// client's items as they were, and says what it did.
func TestSettingsMenuImportsTheEarlierClientsCredentialsOnRequest(t *testing.T) {
	const prefix = "app.lithe.desktop.plugin-credentials."
	backend := mapSecrets{credentials.Service("p") + "|kept": "new"}
	legacy := &earlierSecrets{
		items: []credentials.LegacyItem{
			{Service: prefix + "p", PluginID: "p", Key: "token"},
			{Service: prefix + "p", PluginID: "p", Key: "kept"},
		},
		secrets: map[string]string{prefix + "p|token": "old-token", prefix + "p|kept": "old"},
	}
	before := maps.Clone(legacy.secrets)
	h := credentialHarness(t, backend, legacy)
	lang := h.app.language()
	label := i18n.Shared(lang, "desktop.credentials.importLegacy")

	h.openGearMenu()
	item := center(h.hitLabeled(label))
	if err := h.driver.Click(item.X, item.Y); err != nil {
		t.Fatal(err)
	}
	h.settle()
	if !h.app.credentialImport.confirming || !h.showsWrapped(i18n.Shared(lang, "desktop.credentials.importLegacyDescription")) {
		t.Fatal("the menu item did not explain the import before running it")
	}
	if len(backend) != 1 {
		t.Fatalf("secrets before the user confirmed = %v", backend)
	}

	h.clickNamed(i18n.Shared(lang, "desktop.credentials.importLegacyConfirm"))
	h.settle()
	h.await("the import", func() bool { return !h.app.credentialImport.busy })
	h.settle()
	want := mapSecrets{credentials.Service("p") + "|kept": "new", credentials.Service("p") + "|token": "old-token"}
	if !maps.Equal(backend, want) {
		t.Fatalf("secrets after the import = %v, want %v", backend, want)
	}
	if !maps.Equal(legacy.secrets, before) {
		t.Fatalf("the earlier client's secrets changed: %v", legacy.secrets)
	}
	done := i18n.SharedFormat(lang, "desktop.credentials.importLegacyDone", map[string]string{"imported": "1", "kept": "1", "failed": "0"})
	if h.app.notice != done {
		t.Fatalf("notice = %q, want %q", h.app.notice, done)
	}
}

// Without an earlier client's store to read, the settings menu does not offer the import.
func TestSettingsMenuOffersNoImportWithoutAnEarlierClient(t *testing.T) {
	h := credentialHarness(t, mapSecrets{}, nil)
	h.openGearMenu()
	if !h.app.title.gearOpen || !h.shows(h.app.text.Title.Preferences) {
		t.Fatal("the settings menu did not open")
	}
	if h.shows(i18n.Shared(h.app.language(), "desktop.credentials.importLegacy")) {
		t.Fatal("the settings menu offers to import without an earlier client")
	}
}
