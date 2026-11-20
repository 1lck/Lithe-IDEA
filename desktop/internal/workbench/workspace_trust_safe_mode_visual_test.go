//go:build vivahead && lithevisual

package workbench

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/headless"
)

// TestVisualSafeModeHoldsBackProjectCode captures what safe mode shows in place of the tools
// that would run project code (#2208): the language server the status bar holds back, with its
// trust action, and the Commit window that reads no Git.
func TestVisualSafeModeHoldsBackProjectCode(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, theme := range []string{"light", "dark"} {
		for _, language := range []string{"en", "zh-Hans"} {
			t.Run(theme+"/"+language, func(t *testing.T) {
				visualSafeModeLanguageServer(t, out, theme, language)
				visualSafeModeCommit(t, out, theme, language)
			})
		}
	}
}

// safeModeVisualHarness opens a headless window of width × height in theme and language.
func safeModeVisualHarness(t *testing.T, kernel Kernel, theme, language string, width, height int) (*harness, *headless.Session) {
	t.Helper()
	prefs := store.At(t.TempDir())
	if err := prefs.Save(settingsFile, settings{Theme: themeChoice(theme), Language: language, DisableAutoSave: true}); err != nil {
		t.Fatal(err)
	}
	var session *headless.Session
	h := newHarnessWithDriver(t, Options{Kernel: kernel, Store: prefs, Languages: []string{language}}, func(config app.Config) (*app.Driver, func(), error) {
		config.Width, config.Height = width, height
		var err error
		session, err = headless.Open(config, nil, headless.Options{})
		if err != nil {
			return nil, nil, err
		}
		return session.Driver(), session.Close, nil
	})
	return h, session
}

func visualSafeModeLanguageServer(t *testing.T, out, theme, language string) {
	t.Helper()
	root := t.TempDir()
	file := filepath.Join(root, "example.fixture")
	if err := os.WriteFile(file, []byte("let answer = 42;\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	h, session := safeModeVisualHarness(t, &testKernel{Client: core.NewClient()}, theme, language, 1200, 760)
	h.open(root)
	p := h.app.project
	h.app.openFile(p, file)
	h.settleChain()
	d := p.docs.byPath(file)
	if d == nil {
		t.Fatal("fixture document did not open")
	}
	d.languageID = "fixture"
	h.app.applyProjectTrust(p, false)
	h.app.pluginServerMu.Lock()
	if h.app.pluginServerFailed == nil {
		h.app.pluginServerFailed = make(map[string]*failedPluginServer)
	}
	h.app.pluginServerFailed["fixture"] = &failedPluginServer{
		pluginID: "dev.example.settings", languageID: "fixture", version: "1.0.0", project: p,
		message: i18n.Shared(h.app.language(), "desktop.trust.lspSafeMode"), untrusted: true,
	}
	h.app.pluginServerMu.Unlock()
	h.app.invalidator.Invalidate()
	h.settleChain()
	h.click(center(h.button(itemLSP)))
	h.settleChain()
	h.clickNamed("dev.example.settings")
	h.settleChain()
	if err := session.Advance(time.Second); err != nil {
		t.Fatal(err)
	}
	if err := session.Screenshot(filepath.Join(out, "safe-mode-lsp-"+theme+"-"+language+".png")); err != nil {
		t.Fatal(err)
	}
}

func visualSafeModeCommit(t *testing.T, out, theme, language string) {
	t.Helper()
	dir := newTestRepository(t)
	h, session := safeModeVisualHarness(t, &gitKernel{Client: core.NewClient()}, theme, language, 1200, 760)
	h.open(dir)
	p := h.app.project
	h.app.applyProjectTrust(p, false)
	h.click(center(h.button(itemCommit)))
	h.settleChain()
	if !p.git.safeMode {
		t.Fatalf("the project is not in safe mode: %+v", p.git)
	}
	if err := session.Advance(time.Second); err != nil {
		t.Fatal(err)
	}
	if err := session.Screenshot(filepath.Join(out, "safe-mode-commit-"+theme+"-"+language+".png")); err != nil {
		t.Fatal(err)
	}
}
