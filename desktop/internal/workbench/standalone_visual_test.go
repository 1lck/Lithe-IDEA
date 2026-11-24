//go:build vivahead && lithevisual

package workbench

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/1lck/Lithe-IDEA/desktop/internal/webpreview"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/headless"
)

func TestVisualStandalone(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0755); err != nil {
		t.Fatal(err)
	}
	for _, theme := range []string{"dark", "light"} {
		for _, language := range []string{"en-US", "zh-Hans"} {
			t.Run(theme+"-"+language, func(t *testing.T) {
				root := t.TempDir()
				path := filepath.Join(root, "hello.go")
				if err := os.WriteFile(path, []byte("package main\n\nimport \"fmt\"\n\n// A file opened directly from the terminal.\nfunc main() {\n\tfmt.Println(\"Hello, Lithe!\")\n}\n"), 0600); err != nil {
					t.Fatal(err)
				}
				prefs := store.At(t.TempDir())
				if err := prefs.Save(settingsFile, map[string]string{"theme": theme}); err != nil {
					t.Fatal(err)
				}
				options := DesktopOptions(core.NewClient(), prefs, "test")
				options.Languages = []string{language}
				options.OpenFile = path
				var session *headless.Session
				h := newHarnessWithDriver(t, options, func(config app.Config) (*app.Driver, func(), error) {
					config.Width, config.Height = 1000, 640
					var err error
					session, err = headless.Open(config, nil, headless.Options{})
					if err != nil {
						return nil, nil, err
					}
					return session.Driver(), session.Close, nil
				})
				h.app.openStandaloneFile(path)
				h.await("standalone file", func() bool { return h.app.project != nil && h.app.project.docs.byPath(path) != nil })
				h.settle()
				if err := session.Screenshot(filepath.Join(out, "single-file-"+theme+"-"+language+".png")); err != nil {
					t.Fatal(err)
				}
				if runtime.GOOS != "windows" {
					h.app.settings.TerminalShell = "/bin/sh"
					h.clickNamed(h.app.text.Tools.Terminal)
					h.await("terminal panel", func() bool { return len(h.app.project.terms.list) == 1 })
					term := h.app.project.terms.list[0]
					if !term.view.SendLine("printf '\\nHello from the integrated terminal\\n'; pwd -P") {
						t.Fatal("terminal rejected command")
					}
					realRoot, err := filepath.EvalSymlinks(root)
					if err != nil {
						t.Fatal(err)
					}
					awaitStateWithin(t, h, 5*time.Second, "actual shell output", func() bool {
						term.view.Pump()
						return strings.Contains(term.view.RetainedText(1<<16), realRoot)
					})
					h.settle()
					if err := session.Screenshot(filepath.Join(out, "single-file-terminal-"+theme+"-"+language+".png")); err != nil {
						t.Fatal(err)
					}
				}
			})
		}
	}
}

// TestVisualStandaloneMarkdown captures a Markdown file opened alone, its source beside the page
// with the view switch and the Contents button in the tab strip (#2324).
func TestVisualStandaloneMarkdown(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0755); err != nil {
		t.Fatal(err)
	}
	text := "# Notes\n\nA file opened **alone**, its page beside the source.\n\n## List\n\n- one\n- two\n\n## Code\n\n```go\nfmt.Println(\"Hello, Lithe!\")\n```\n\n> A quote.\n"
	for _, theme := range []string{"dark", "light"} {
		for _, language := range []string{"en-US", "zh-Hans"} {
			t.Run(theme+"-"+language, func(t *testing.T) {
				root := t.TempDir()
				path := filepath.Join(root, "notes.md")
				if err := os.WriteFile(path, []byte(text), 0600); err != nil {
					t.Fatal(err)
				}
				prefs := store.At(t.TempDir())
				if err := prefs.Save(settingsFile, map[string]string{"theme": theme}); err != nil {
					t.Fatal(err)
				}
				options := DesktopOptions(core.NewClient(), prefs, "test")
				options.Languages = []string{language}
				options.OpenFile = path
				var session *headless.Session
				h := newHarnessWithDriver(t, options, func(config app.Config) (*app.Driver, func(), error) {
					config.Width, config.Height = 1000, 640
					var err error
					session, err = headless.Open(config, nil, headless.Options{})
					if err != nil {
						return nil, nil, err
					}
					return session.Driver(), session.Close, nil
				})
				h.app.openStandaloneFile(path)
				h.await("standalone Markdown file", func() bool { return h.app.project != nil && h.app.project.docs.byPath(path) != nil })
				h.settle()
				if err := session.Screenshot(filepath.Join(out, "single-file-markdown-"+theme+"-"+language+".png")); err != nil {
					t.Fatal(err)
				}
			})
		}
	}
}

// TestVisualStandaloneHTMLAndSVG captures Single File Mode previews for HTML (split view with
// title and navigation controls) and SVG (interactive mode toggle and browser action) in light
// and dark themes and both languages.
func TestVisualStandaloneHTMLAndSVG(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, theme := range []string{"dark", "light"} {
		for _, language := range []string{"en-US", "zh-Hans"} {
			t.Run(theme+"-"+language, func(t *testing.T) {
				root := t.TempDir()
				htmlPath := filepath.Join(root, "preview.html")
				svgPath := filepath.Join(root, "diagram.svg")
				if err := os.WriteFile(htmlPath, []byte("<!doctype html>\n<html>\n<head><title>Interactive Preview</title></head>\n<body><button>Click</button></body>\n</html>\n"), 0o600); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(svgPath, []byte("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"120\" height=\"80\">\n  <rect width=\"120\" height=\"80\" rx=\"8\"/>\n</svg>\n"), 0o600); err != nil {
					t.Fatal(err)
				}
				prefs := store.At(t.TempDir())
				if err := prefs.Save(settingsFile, map[string]string{"theme": theme}); err != nil {
					t.Fatal(err)
				}
				options := DesktopOptions(core.NewClient(), prefs, "test")
				options.Languages = []string{language}
				options.OpenFile = htmlPath
				var session *headless.Session
				h := newHarnessWithDriver(t, options, func(config app.Config) (*app.Driver, func(), error) {
					config.Width, config.Height = 1000, 640
					var err error
					session, err = headless.Open(config, nil, headless.Options{})
					if err != nil {
						return nil, nil, err
					}
					return session.Driver(), session.Close, nil
				})
				pages := fakePreviews(h)
				h.app.openStandaloneFile(htmlPath)
				h.await("standalone HTML", func() bool { return h.app.project != nil && h.app.project.docs.byPath(htmlPath) != nil })
				h.settle()
				h.settle()
				if len(*pages) > 0 {
					(*pages)[0].title = "Interactive Preview"
					(*pages)[0].canGoBack = true
					h.app.invalidator.Invalidate()
					h.settle()
				}
				if err := session.Screenshot(filepath.Join(out, "single-file-html-"+theme+"-"+language+".png")); err != nil {
					t.Fatal(err)
				}

				h.app.openFile(h.app.project, svgPath)
				h.await("standalone SVG", func() bool { return h.app.project.docs.byPath(svgPath) != nil })
				h.settle()
				h.settle()
				if len(*pages) > 1 {
					(*pages)[1].load()
					(*pages)[1].config.OnMessage(webpreview.Message{Type: "scale", Scale: 1, Fit: 1, Width: 120, Height: 80})
					h.settle()
				}
				if err := session.Screenshot(filepath.Join(out, "single-file-svg-"+theme+"-"+language+".png")); err != nil {
					t.Fatal(err)
				}
			})
		}
	}
}
