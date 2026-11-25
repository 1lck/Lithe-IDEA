//go:build vivahead && lithevisual

package workbench

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/headless"
)

// TestVisualPointerHover captures the workbench's real hover and navigation
// surfaces. Headless rendering has no native web engine; native occlusion needs
// platform acceptance, while the behavioral test checks the hover's layer.
func TestVisualPointerHover(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, theme := range []string{"light", "dark"} {
		for _, language := range []string{"zh-Hans", "en-US"} {
			t.Run(theme+"-"+language, func(t *testing.T) {
				prefs := store.At(t.TempDir())
				if err := prefs.Save(settingsFile, map[string]string{"theme": theme}); err != nil {
					t.Fatal(err)
				}
				kernel := &semanticTestKernel{testKernel: &testKernel{Client: core.NewClient()}}
				var session *headless.Session
				h := newHarnessWithDriver(t, Options{Kernel: kernel, Store: prefs, Languages: []string{language}}, func(config app.Config) (*app.Driver, func(), error) {
					config.Width, config.Height = 1000, 640
					var err error
					session, err = headless.Open(config, nil, headless.Options{})
					if err != nil {
						return nil, nil, err
					}
					return session.Driver(), session.Close, nil
				})
				f := openSemanticFixture(t, h, kernel)
				h.app.semantics.hoverDelay = -1
				f.openPointerHover(t, markdownHoverResult(t, "```java\nint one()\n```\n\n---\n\nReturns **one**.\n\n[Documentation](https://example.invalid/one)", nil))
				capture := func(scene string) {
					t.Helper()
					if err := session.Screenshot(filepath.Join(out, scene+"-"+theme+"-"+language+".png")); err != nil {
						t.Fatal(err)
					}
				}
				capture("pointer-hover")
				h.key(gfx.KeyEscape)
				h.app.navigation.delay = -1
				h.click(center(h.button(itemCaret)))
				awaitDocumentState(t, h, func() bool { return h.app.navigation.target != nil && h.driver.Snapshot().Focused == navigationField })
				capture("navigation-overlay")
				h.key(gfx.KeyEscape)
				if h.app.navigation.open {
					t.Fatal("Escape did not dismiss navigation")
				}
			})
		}
	}
}

// TestVisualHoverContentsContract draws the linked Core fixture with the real
// hover renderer. The fixture verifies presentation without an installed plugin.
func TestVisualHoverContentsContract(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, c := range hoverContentsCases(t) {
		if c.Name != "bare-marked-string" && c.Name != "language-marked-string" {
			continue
		}
		for _, theme := range []string{"light", "dark"} {
			for _, language := range []string{"zh-Hans", "en-US"} {
				name := c.Name + "-" + theme + "-" + language
				t.Run(name, func(t *testing.T) {
					prefs := store.At(t.TempDir())
					if err := prefs.Save(settingsFile, map[string]string{"theme": theme}); err != nil {
						t.Fatal(err)
					}
					kernel := &semanticTestKernel{testKernel: &testKernel{Client: core.NewClient()}}
					var session *headless.Session
					h := newHarnessWithDriver(t, Options{Kernel: kernel, Store: prefs, Languages: []string{language}}, func(config app.Config) (*app.Driver, func(), error) {
						config.Width, config.Height = 1000, 640
						var err error
						session, err = headless.Open(config, nil, headless.Options{})
						if err != nil {
							return nil, nil, err
						}
						return session.Driver(), session.Close, nil
					})
					f := openSemanticFixture(t, h, kernel)
					h.app.semantics.hoverDelay = -1
					f.openPointerHover(t, c.result(t))
					page := h.app.semantics.hover.page
					awaitDocumentState(t, h, func() bool { return page.tokens != nil })
					h.settle()
					if err := session.Screenshot(filepath.Join(out, "hover-contents-"+name+".png")); err != nil {
						t.Fatal(err)
					}
				})
			}
		}
	}
}
