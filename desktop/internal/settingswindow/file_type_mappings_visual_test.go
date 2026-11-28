//go:build vivahead && lithevisual

package settingswindow

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/headless"
)

type visualFileTypeMappingsSource struct {
	snap FileTypeMappingsSnapshot
}

func (s *visualFileTypeMappingsSource) Load(context.Context) (FileTypeMappingsSnapshot, error) {
	return cloneFileTypeMappingsSnapshot(s.snap), nil
}

func (s *visualFileTypeMappingsSource) Save(_ context.Context, _, next FileTypeMappingsSnapshot) (FileTypeMappingsSaveResult, error) {
	s.snap = cloneFileTypeMappingsSnapshot(next)
	return FileTypeMappingsSaveResult{Snapshot: cloneFileTypeMappingsSnapshot(s.snap)}, nil
}

func TestVisualFileTypeMappings(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, language := range []i18n.Language{i18n.Chinese, i18n.English} {
		for _, theme := range []string{"dark", "light"} {
			t.Run(language.Code()+"-"+theme, func(t *testing.T) {
				src := &visualFileTypeMappingsSource{
					snap: FileTypeMappingsSnapshot{
						HasWorkspace:       true,
						WorkspaceRoot:      "/Users/demo/Projects/uv-service",
						GlobalConfigPath:   "/Users/demo/Library/Application Support/Lithe Desktop/file-type-mappings.json",
						ProjectConfigPath:  "/Users/demo/Projects/uv-service/.lithe/file-type-mappings.json",
						GlobalFingerprint:  "abc",
						ProjectFingerprint: "def",
						Global: []core.FileTypeMapping{
							{Pattern: "*.lock", LanguageID: "toml"},
							{Pattern: "uv.lock", LanguageID: "ini"},
							{Pattern: "deploy/*.cfg", LanguageID: "yaml"},
						},
						Project: []core.FileTypeMapping{
							{Pattern: "uv.lock", LanguageID: "toml"},
						},
						Builtins: []core.FileTypeMapping{
							{Pattern: "uv.lock", LanguageID: "toml"},
							{Pattern: "Cargo.lock", LanguageID: "toml"},
							{Pattern: "poetry.lock", LanguageID: "toml"},
							{Pattern: "bun.lock", LanguageID: "jsonc"},
							{Pattern: "flake.lock", LanguageID: "json"},
							{Pattern: ".clang-format", LanguageID: "yaml"},
						},
						KnownLanguageIDs: []string{"ini", "json", "jsonc", "toml", "yaml"},
					},
				}
				w := newWindow(NewController(Options{
					FileTypeMappings: src,
					Text:             func() *i18n.Messages { return i18n.For(language) },
					Language:         func() i18n.Language { return language },
					SystemLanguage:   language,
					SystemDark:       func() bool { return theme == "dark" },
				}), Values{Language: language.Code(), Theme: theme})
				w.sess.page = pageFileTypeMappings
				config := w.config()
				config.Width, config.Height = 1180, 820
				session, err := headless.Open(config, nil, headless.Options{})
				if err != nil {
					t.Fatal(err)
				}
				t.Cleanup(session.Close)
				d := &windowDriver{t: t, w: w, driver: session.Driver()}
				deadline := time.NewTimer(5 * time.Second)
				defer deadline.Stop()
				for !(w.fileTypeDraft.ready && !w.fileTypeDraft.busy) {
					select {
					case <-d.driver.Wakes():
						d.pump()
					case <-deadline.C:
						t.Fatal("timed out waiting for file type mappings page to load")
					}
					d.pump()
				}
				d.pump()
				d.pump()
				if err := session.Screenshot(filepath.Join(out, "file-type-mappings-"+language.Code()+"-"+theme+".png")); err != nil {
					t.Fatal(err)
				}
			})
		}
	}
}
