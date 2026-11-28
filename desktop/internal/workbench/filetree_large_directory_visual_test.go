//go:build vivahead && lithevisual

package workbench

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/headless"
)

// TestVisualProjectTreeLargeDirectory uses real files, native Git and the production
// indexing/listing boundary. It saves the failed tree before asserting, so running
// against the old Core produces reproducible visual evidence of the timeout.
// Run explicitly with lithevisual; it never reads an installed plugin or user project.
func TestVisualProjectTreeLargeDirectory(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0o755); err != nil {
		t.Fatal(err)
	}
	requireTestGit(t)
	for _, scene := range []struct{ theme, language string }{{"light", "zh-Hans"}, {"dark", "en-US"}} {
		t.Run(scene.theme+"-"+scene.language, func(t *testing.T) {
			root := filepath.Join(t.TempDir(), "LargeDirectoryProject")
			if err := os.MkdirAll(filepath.Join(root, "00-source"), 0o700); err != nil {
				t.Fatal(err)
			}
			gitRun(t, root, "init", "--quiet")
			if err := os.WriteFile(filepath.Join(root, ".gitignore"), []byte("generated*/\n"), 0o600); err != nil {
				t.Fatal(err)
			}
			const count = 500
			for i := range count {
				if err := os.Mkdir(filepath.Join(root, fmt.Sprintf("generated%05d", i)), 0o700); err != nil {
					t.Fatal(err)
				}
			}
			file := filepath.Join(root, "00-source", "Hello.txt")
			if err := os.Mkdir(filepath.Join(root, "00-source", "Empty"), 0o700); err != nil {
				t.Fatal(err)
			}
			const contents = "Large directory regression\n\n500 ignored sibling folders.\nThe project tree and this file should open normally.\n"
			if err := os.WriteFile(file, []byte(contents), 0o600); err != nil {
				t.Fatal(err)
			}

			// Install the same default policy before opening the window, avoiding a
			// race between the first paint and asynchronous policy installation.
			// The window keeps its own normal lease and release lifecycle.
			client := core.NewClient()
			ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
			status, err := client.ConfigureIndexing(ctx, root, "visual-large-tree", core.IndexingPolicyOf(nil, true), false)
			cancel()
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() {
				ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
				defer cancel()
				if _, err := client.ReleaseIndexing(ctx, root, "visual-large-tree", status.Revision); err != nil {
					t.Errorf("release indexing: %v", err)
				}
			})
			prefs := store.At(t.TempDir())
			if err := prefs.Save(settingsFile, map[string]string{"theme": scene.theme}); err != nil {
				t.Fatal(err)
			}
			var session *headless.Session
			h := newHarnessWithDriver(t, Options{Kernel: &testKernel{Client: client}, Store: prefs, Languages: []string{scene.language}}, func(config app.Config) (*app.Driver, func(), error) {
				config.Width, config.Height = 1280, 800
				var err error
				session, err = headless.Open(config, nil, headless.Options{Scale: 1})
				if err != nil {
					return nil, nil, err
				}
				return session.Driver(), session.Close, nil
			})
			started := time.Now()
			h.open(root)
			p := h.app.project
			if p == nil {
				t.Fatal("project did not open")
			}
			h.await("the root listing or failure", func() bool {
				return p.tree.failed != "" || p.tree.root != nil && p.tree.root.listed
			})
			t.Logf("directory_count=%d tree_elapsed=%s failure=%q", count, time.Since(started), p.tree.failed)
			h.settle()
			if err := session.Screenshot(filepath.Join(out, "large-tree-"+scene.theme+"-"+scene.language+".png")); err != nil {
				t.Fatal(err)
			}
			if p.tree.failed != "" {
				t.Fatalf("readable project with %d ignored directories failed: %s", count, p.tree.failed)
			}
			if got := len(p.tree.root.children); got != count+2 {
				t.Fatalf("root children = %d, want %d", got, count+2)
			}
			h.clickNamed("00-source")
			h.await("the source folder", func() bool {
				n := p.tree.find("00-source")
				return n != nil && n.listed
			})
			h.settle()
			empty := p.tree.find("00-source/Empty")
			if empty == nil || empty.listed || empty.empty {
				t.Fatal("expected an unchecked folder before the first click")
			}
			if err := session.Screenshot(filepath.Join(out, "empty-before-"+scene.theme+"-"+scene.language+".png")); err != nil {
				t.Fatal(err)
			}
			h.clickNamed("Empty")
			h.await("confirmed empty folder", func() bool { return empty.listed && empty.empty && !empty.expanded })
			h.settle()
			if err := session.Screenshot(filepath.Join(out, "empty-after-"+scene.theme+"-"+scene.language+".png")); err != nil {
				t.Fatal(err)
			}
			h.clickNamed("Hello.txt")
			h.await("the opened document", func() bool { return p.docs.byPath(file) != nil })
			h.settle()
			d := p.docs.byPath(file)
			if got := d.view.TextSnapshot().String(); got != contents {
				t.Fatalf("opened document = %q, want %q", got, contents)
			}
			if err := session.Screenshot(filepath.Join(out, "large-tree-file-"+scene.theme+"-"+scene.language+".png")); err != nil {
				t.Fatal(err)
			}
		})
	}
}
