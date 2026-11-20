package settingswindow

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/marketplace"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginhost"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginruntime"
	"github.com/1lck/Lithe-IDEA/desktop/internal/toolchain"
	"github.com/vivaui/viva/app"
)

const (
	fixtureCommandDirectory = "/data/commands/fixture-ls"
	fixtureDigest           = "2f114a990e1b368dd1dbd33c80c0e719767af2d228391ec0df0571c957f9ac91"
)

// fakeCommandInstaller is a plugin whose language server misses fixture-ls, which an installer
// provides, and whose backend misses fixture-backend, which none does. An installation prints
// one line, or with download reports a download half done, and then waits for release or a
// cancel.
type fakeCommandInstaller struct {
	download  bool
	mu        sync.Mutex
	installed bool
	targets   []string
	printed   chan struct{}
	release   chan struct{}
	cancelled chan struct{}
}

func newFakeCommandInstaller() *fakeCommandInstaller {
	return &fakeCommandInstaller{printed: make(chan struct{}), release: make(chan struct{}), cancelled: make(chan struct{})}
}

func (f *fakeCommandInstaller) Missing(context.Context, string) ([]MissingCommand, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	missing := []MissingCommand{{Commands: []string{"fixture-backend"}}}
	if !f.installed {
		missing = append(missing, MissingCommand{Kind: CapabilityLanguageServer, ID: "fixture", Commands: []string{"fixture-ls"}, Installer: "fixture-ls", Tool: "Builder"})
	}
	return missing, nil
}

func (f *fakeCommandInstaller) Offer(context.Context, string, string) (CommandInstallOffer, error) {
	if f.download {
		return CommandInstallOffer{
			Installer: "fixture-ls", Commands: []string{"fixture-ls"}, MayUseNetwork: true, Timeout: time.Minute,
			Download: &CommandInstallDownload{
				Version: "1.2.3", URL: "https://downloads.example.org/fixture-ls-1.2.3.zip",
				Mirrors: []string{"https://mirror.example.net/fixture-ls-1.2.3.zip"}, SHA256: fixtureDigest,
			},
			Targets: []CommandInstallTarget{{Target: core.CommandInstallManaged, Directory: fixtureCommandDirectory}},
		}, nil
	}
	return CommandInstallOffer{
		Installer: "fixture-ls", Commands: []string{"fixture-ls"}, Tool: "Builder", Executable: "/tools/builder",
		MayUseNetwork: true, Timeout: time.Minute,
		Targets: []CommandInstallTarget{
			{Target: core.CommandInstallManaged, CommandLine: "/tools/builder install fixture-ls", Environment: []string{"FIXTURE_BIN=" + fixtureCommandDirectory}, Directory: fixtureCommandDirectory},
			{Target: core.CommandInstallToolDefault, CommandLine: "/tools/builder install fixture-ls"},
		},
	}, nil
}

func (f *fakeCommandInstaller) Install(ctx context.Context, _, _, target string, output func(string), progress func(pluginruntime.Progress)) (string, error) {
	f.mu.Lock()
	f.targets = append(f.targets, target)
	f.mu.Unlock()
	if f.download {
		progress(pluginruntime.Progress{ID: "fixture-ls", Phase: "downloading", Received: 512 << 10, Total: 1 << 20})
	} else {
		output("fixture: downloading")
	}
	close(f.printed)
	select {
	case <-f.release:
	case <-ctx.Done():
		close(f.cancelled)
		return "", ctx.Err()
	}
	f.mu.Lock()
	f.installed = true
	f.mu.Unlock()
	return fixtureCommandDirectory, nil
}

func (f *fakeCommandInstaller) installedTargets() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.targets...)
}

func commandInstallWindow(f *fakeCommandInstaller) *window {
	facts := []PluginFacts{{
		ID: "dev.lithe.test.commands", Name: "Commands Fixture", Vendor: "Test", Version: "1.0.0", Source: PluginSourceDisk,
		Permissions:  []string{"commands.install", "languageServer.launch"},
		Capabilities: []PluginCapability{{Kind: CapabilityLanguageServer, ID: "fixture", Title: "fixture-ls", Commands: []string{"fixture-ls"}}},
	}}
	w := newWindow(NewController(Options{
		Language: func() i18n.Language { return i18n.English },
		Marketplace: func(context.Context) (marketplace.Snapshot, error) {
			return marketplace.Snapshot{}, nil
		},
		InstalledPlugins: func() []PluginFacts { return facts },
		PluginState: func(string) PluginState {
			return PluginState{Installed: true, Version: "1.0.0", Enabled: true}
		},
		CommandInstalls: f,
	}), Values{})
	w.sess.page = pagePlugins
	w.installed.tab = installedFeatures
	return w
}

func waitClosed(t *testing.T, what string, done <-chan struct{}) {
	t.Helper()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatalf("timed out waiting for %s", what)
	}
}

func TestCapabilityCardInstallsItsMissingCommand(t *testing.T) {
	f := newFakeCommandInstaller()
	w := commandInstallWindow(f)
	d := openWindow(t, w, func(config *app.Config) { config.Width, config.Height = 1100, 800 })
	words := func(key string) string { return i18n.Shared(i18n.English, key) }
	format := func(key string, values map[string]string) string { return i18n.SharedFormat(i18n.English, key, values) }
	missing := format("desktop.plugins.commandMissing", map[string]string{"commands": "fixture-ls"})
	d.until("the card to report the missing command", func() bool { return d.text(missing) })
	if !d.text(format("desktop.plugins.commandMissingBanner", map[string]string{"commands": "fixture-backend"})) {
		t.Fatal("a missing command no card shows has no banner")
	}

	d.click(words("desktop.marketplace.install"))
	prompt := format("desktop.plugins.commandInstallPrompt", map[string]string{"tool": "Builder", "commands": "fixture-ls"})
	d.until("the install offer", func() bool { return d.text(prompt) })
	for _, shown := range []string{
		words("desktop.plugins.commandInstallNetwork"),
		words("desktop.plugins.commandInstallManaged"),
		fixtureCommandDirectory,
		"FIXTURE_BIN=" + fixtureCommandDirectory,
		"/tools/builder install fixture-ls",
		// The tool's own directory is unknown, so that target cannot be chosen.
		format("desktop.plugins.commandInstallNoDirectory", map[string]string{"tool": "Builder"}),
	} {
		if !d.text(shown) {
			t.Fatalf("the offer does not show %q", shown)
		}
	}

	// The dialog is in front, so this is its Install button.
	d.click(words("desktop.marketplace.install"))
	waitClosed(t, "the installation to start", f.printed)
	d.until("the installation's output", func() bool { return d.text("fixture: downloading") })
	close(f.release)
	installed := format("desktop.plugins.commandInstalled", map[string]string{"directory": fixtureCommandDirectory})
	d.until("the installed message", func() bool { return d.text(installed) })
	if targets := f.installedTargets(); len(targets) != 1 || targets[0] != core.CommandInstallManaged {
		t.Fatalf("installed into %v, want the managed target", targets)
	}
	d.click(words("ui.done"))
	d.until("the card to drop the installed command", func() bool { return w.commands.dialog == nil && !d.text(missing) })
}

func TestDownloadInstallerShowsItsArchiveAndProgress(t *testing.T) {
	f := newFakeCommandInstaller()
	f.download = true
	w := commandInstallWindow(f)
	d := openWindow(t, w, func(config *app.Config) { config.Width, config.Height = 1100, 800 })
	words := func(key string) string { return i18n.Shared(i18n.English, key) }
	format := func(key string, values map[string]string) string { return i18n.SharedFormat(i18n.English, key, values) }
	missing := format("desktop.plugins.commandMissing", map[string]string{"commands": "fixture-ls"})
	d.until("the card to report the missing command", func() bool { return d.text(missing) })

	d.click(words("desktop.marketplace.install"))
	prompt := format("desktop.plugins.commandInstallDownloadPrompt", map[string]string{"commands": "fixture-ls", "version": "1.2.3"})
	d.until("the download offer", func() bool { return d.text(prompt) })
	for _, shown := range []string{
		words("desktop.plugins.commandInstallDownloadNetwork"),
		"https://downloads.example.org/fixture-ls-1.2.3.zip",
		words("desktop.plugins.commandInstallMirror"),
		"https://mirror.example.net/fixture-ls-1.2.3.zip",
		words("desktop.plugins.commandInstallDigest"),
		fixtureDigest,
		words("desktop.plugins.commandInstallManaged"),
		fixtureCommandDirectory,
	} {
		// The network note is long enough to wrap in the dialog.
		if !d.showsWrapped(shown) {
			t.Fatalf("the download offer does not show %q", shown)
		}
	}
	// A download runs no tool, so there is neither a tool's prompt nor a command line.
	for _, hidden := range []string{
		words("desktop.plugins.commandInstallCommand"),
		words("desktop.plugins.commandInstallNetwork"),
	} {
		if d.showsWrapped(hidden) {
			t.Fatalf("the download offer shows %q", hidden)
		}
	}

	d.click(words("desktop.marketplace.install"))
	waitClosed(t, "the download to start", f.printed)
	downloading := format("desktop.marketplace.runtimeDownloading", map[string]string{"dependency": "fixture-ls", "received": "0.5", "total": "1.0"})
	d.until("the download's progress", func() bool { return d.text(downloading) })
	close(f.release)
	installed := format("desktop.plugins.commandInstalled", map[string]string{"directory": fixtureCommandDirectory})
	d.until("the installed message", func() bool { return d.text(installed) })
	if targets := f.installedTargets(); len(targets) != 1 || targets[0] != core.CommandInstallManaged {
		t.Fatalf("installed into %v, want the managed target", targets)
	}
	d.click(words("ui.done"))
	d.until("the card to drop the installed command", func() bool { return w.commands.dialog == nil && !d.text(missing) })
}

func TestCancellingTheInstallDialogStopsTheInstallation(t *testing.T) {
	f := newFakeCommandInstaller()
	w := commandInstallWindow(f)
	d := openWindow(t, w, func(config *app.Config) { config.Width, config.Height = 1100, 800 })
	words := func(key string) string { return i18n.Shared(i18n.English, key) }
	missing := i18n.SharedFormat(i18n.English, "desktop.plugins.commandMissing", map[string]string{"commands": "fixture-ls"})
	d.until("the card to report the missing command", func() bool { return d.text(missing) })
	d.click(words("desktop.marketplace.install"))
	d.until("the install offer", func() bool { return w.commands.dialog != nil && w.commands.dialog.offer != nil })
	d.pump()
	d.click(words("desktop.marketplace.install"))
	waitClosed(t, "the installation to start", f.printed)
	d.until("the installation's output", func() bool { return d.text("fixture: downloading") })
	d.click(words("ui.cancel"))
	d.pump()
	waitClosed(t, "the cancel to reach the installation", f.cancelled)
	if w.commands.dialog != nil {
		t.Fatal("the dialog stayed open after the cancel")
	}
}

func TestCommandInstallFailuresAreLocalized(t *testing.T) {
	format := func(key string, values map[string]string) string { return i18n.SharedFormat(i18n.English, key, values) }
	for _, test := range []struct {
		err  error
		want string
	}{
		{&pluginhost.CommandInstallError{Code: pluginhost.CommandInstallFailedCode, ExitCode: 3}, format("desktop.plugins.commandInstallFailed", map[string]string{"code": "3"})},
		{&pluginhost.CommandInstallError{Code: pluginhost.CommandInstallFailedCode, ExitCode: -1}, i18n.Shared(i18n.English, "desktop.plugins.commandInstallStopped")},
		{&pluginhost.CommandInstallError{Code: pluginhost.CommandInstallTimedOutCode, Timeout: 5 * time.Minute}, format("desktop.plugins.commandInstallTimedOut", map[string]string{"seconds": "300"})},
		{&pluginhost.CommandInstallError{Code: pluginhost.CommandInstallCommandsMissingCode, Commands: []string{"a", "b"}, Directory: "/d"},
			format("desktop.plugins.commandInstallCommandsMissing", map[string]string{"commands": commandList([]string{"a", "b"}), "directory": "/d"})},
		{&pluginhost.CommandInstallError{Code: pluginhost.CommandInstallDownloadFailedCode, Err: errors.New("HTTP 404")},
			format("desktop.plugins.commandInstallDownloadFailed", map[string]string{"reason": "HTTP 404"})},
		{&pluginhost.CommandInstallError{Code: pluginhost.CommandInstallChecksumMismatchCode, Err: errors.New("digest differs")},
			i18n.Shared(i18n.English, "desktop.plugins.commandInstallChecksumMismatch")},
		{&pluginhost.CommandInstallError{Code: pluginhost.CommandInstallArchiveInvalidCode, Err: errors.New("entry escapes the root")},
			format("desktop.plugins.commandInstallArchiveInvalid", map[string]string{"reason": "entry escapes the root"})},
		{&toolchain.UnavailableError{Tool: "dev.example:builder", Code: "notFound"}, format("desktop.plugins.commandInstallToolMissing", map[string]string{"tool": "Builder"})},
		{errors.New("disk full"), format("desktop.plugins.commandInstallError", map[string]string{"reason": "disk full"})},
	} {
		if got := commandInstallFailureText(i18n.English, "Builder", test.err); got != test.want {
			t.Errorf("%v: %q, want %q", test.err, got, test.want)
		}
	}
}
