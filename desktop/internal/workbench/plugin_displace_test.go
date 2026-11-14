package workbench

import (
	"archive/zip"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/1lck/Lithe-IDEA/desktop/internal/settingswindow"
)

// servingPluginManifest is a plugin named displayName that declares the Example
// language and a packaged language server for it.
func servingPluginManifest(id, displayName string) string {
	return fmt.Sprintf(`{
  "schemaVersion": 0,
  "id": %q,
  "displayName": %q,
  "version": "1.0.0",
  "pluginAPIVersion": 0,
  "requires": {"languages": 0, "languageServers": 0},
  "vendor": {"id": "io.github.example", "displayName": "Example", "signatureRequirement": "none"},
  "permissions": ["languageServer.launch"],
  "activationEvents": ["onLanguage:example"],
  "languages": [{"id": "example", "displayName": "Example", "fileExtensions": ["example"]}],
  "languageServers": [{"languageID": "example", "launch": {"kind": "packaged", "path": "bin/server"}}]
}`, id, displayName)
}

// writeServingPlugin writes a plugin archive whose manifest serves the Example
// language and returns its path.
func writeServingPlugin(t *testing.T, id, displayName string) string {
	t.Helper()
	archive := filepath.Join(t.TempDir(), id+"-1.0.0.zip")
	file, err := os.Create(archive)
	if err != nil {
		t.Fatal(err)
	}
	writer := zip.NewWriter(file)
	for name, content := range map[string]string{
		id + "/plugin.json": servingPluginManifest(id, displayName),
		id + "/bin/server":  "#!/bin/sh\n",
	} {
		entry, err := writer.Create(name)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := entry.Write([]byte(content)); err != nil {
			t.Fatal(err)
		}
	}
	if err := errors.Join(writer.Close(), file.Close()); err != nil {
		t.Fatal(err)
	}
	return archive
}

// Installing a plugin that serves a language an enabled plugin serves turns that
// plugin off and tells the user which one and why; enabling it again turns the
// newer one off in turn.
func TestInstallingAPluginTurnsOffTheOneServingTheSameLanguage(t *testing.T) {
	const light, full = "io.github.example.light", "io.github.example.full"
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	service, err := pluginservice.Open(core.NewClient(), h.store, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	h.app.plugins = service
	state := func(id string) settingswindow.PluginState {
		states := h.app.pluginState.Load()
		if states == nil {
			return settingswindow.PluginState{}
		}
		return (*states)[id]
	}
	install := func(id, name string) {
		h.app.installPluginFromFile(writeServingPlugin(t, id, name))
		awaitStateWithin(t, h, 30*time.Second, "the install review of "+name, func() bool { return h.app.pluginInstall.open })
		h.app.confirmPluginInstall()
		awaitStateWithin(t, h, 30*time.Second, "the installed "+name, func() bool { return state(id).Installed && state(id).Enabled })
	}
	notice := func(disabled, enabled string) string {
		return i18n.SharedFormat(h.app.language(), "desktop.marketplace.languageServerDisplaced", map[string]string{
			"disabled": disabled, "enabled": enabled, "languages": "Example",
		})
	}

	install(light, "Light")
	install(full, "Full")
	awaitStateWithin(t, h, 30*time.Second, "Light turned off", func() bool { return !state(light).Enabled })
	if want := notice("Light", "Full"); h.app.notice != want {
		t.Fatalf("notice = %q, want %q", h.app.notice, want)
	}

	h.app.setPluginEnabled(light, true)
	awaitStateWithin(t, h, 30*time.Second, "Full turned off", func() bool {
		return state(light).Enabled && !state(full).Enabled
	})
	if want := notice("Full", "Light"); h.app.notice != want {
		t.Fatalf("notice = %q, want %q", h.app.notice, want)
	}
}
