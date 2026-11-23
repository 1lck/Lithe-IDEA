//go:build vivahead

package workbench

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/headless"
)

// TestVisualGitAuthentication captures the questions Git asks while a pull of an open project
// authenticates: the user name with what was typed, the password asked again with its input
// hidden, and whether to retry with the credentials typed in Lithe.
func TestVisualGitAuthentication(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0755); err != nil {
		t.Fatal(err)
	}
	running := make(chan struct{})
	directory := "/Users/dev/Projects/Demo"
	states := []struct {
		name      string
		challenge core.GitAuthChallenge
		typed     string
	}{
		{"user", core.GitAuthChallenge{RequestID: "user", Prompt: "Username for 'https://git.example.com': ", Attempt: 1, WorkingDirectory: directory, Done: running}, "alice"},
		{"secret", core.GitAuthChallenge{RequestID: "secret", Prompt: "Password for 'https://alice@git.example.com': ", Secret: true, Attempt: 2, WorkingDirectory: directory, Done: running}, "s3cret"},
		{"retry", core.GitAuthChallenge{RequestID: "retry", Prompt: "Retry", Retry: true, Attempt: 2, WorkingDirectory: directory, Done: running}, ""},
	}
	for _, scene := range []struct{ theme, language string }{{"dark", "zh-CN"}, {"light", "en-US"}} {
		for _, state := range states {
			name := "git-auth-" + state.name + "-" + scene.theme + "-" + scene.language
			t.Run(name, func(t *testing.T) {
				h, session := visualGitAuthHarness(t, scene.theme, scene.language)
				h.app.post(func(a *App) {
					a.gitAuth.queue = append(a.gitAuth.queue, gitAuthQuestion{GitAuthChallenge: state.challenge})
				})
				h.settle()
				h.settle()
				if state.typed != "" {
					h.typeText(state.typed)
				}
				h.settle()
				if err := session.Screenshot(filepath.Join(out, name+".png")); err != nil {
					t.Fatal(err)
				}
			})
		}
	}
}

// visualGitAuthHarness is a 1280×800 window in theme and language with a project open.
func visualGitAuthHarness(t *testing.T, theme, language string) (*harness, *headless.Session) {
	t.Helper()
	prefs := store.At(t.TempDir())
	if err := prefs.Save(settingsFile, map[string]string{"theme": theme}); err != nil {
		t.Fatal(err)
	}
	var session *headless.Session
	h := newHarnessWithDriver(t, Options{Kernel: &testKernel{Client: core.NewClient()}, Store: prefs, Languages: []string{language}},
		func(config app.Config) (*app.Driver, func(), error) {
			config.Width, config.Height = 1280, 800
			var err error
			session, err = headless.Open(config, nil, headless.Options{Scale: 2})
			if err != nil {
				return nil, nil, err
			}
			return session.Driver(), session.Close, nil
		})
	root := filepath.Join(t.TempDir(), "Demo")
	if err := os.Mkdir(root, 0700); err != nil {
		t.Fatal(err)
	}
	h.open(root)
	return h, session
}
