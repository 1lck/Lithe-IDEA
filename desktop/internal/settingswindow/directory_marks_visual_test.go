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

type visualDirectoryMarksSource struct {
	snap DirectoryMarksSnapshot
}

func (s *visualDirectoryMarksSource) Load(context.Context) (DirectoryMarksSnapshot, error) {
	return cloneDirectoryMarksSnapshot(s.snap), nil
}

func (s *visualDirectoryMarksSource) Save(_ context.Context, next DirectoryMarksSnapshot) (DirectoryMarksSnapshot, error) {
	s.snap = cloneDirectoryMarksSnapshot(next)
	return cloneDirectoryMarksSnapshot(s.snap), nil
}

func (s *visualDirectoryMarksSource) ImportIcon(_ context.Context, sourcePath string) (DirectoryMarksSnapshot, error) {
	s.snap.CustomIcons = append(s.snap.CustomIcons, core.CustomDirectoryIcon{
		ID:   "icon.custom",
		Name: filepath.Base(sourcePath),
		Path: "directory-icons/icon.custom.svg",
	})
	return cloneDirectoryMarksSnapshot(s.snap), nil
}

func (s *visualDirectoryMarksSource) DeleteIcon(_ context.Context, id string) (DirectoryMarksSnapshot, error) {
	next := make([]core.CustomDirectoryIcon, 0, len(s.snap.CustomIcons))
	for _, ci := range s.snap.CustomIcons {
		if ci.ID != id {
			next = append(next, ci)
		}
	}
	s.snap.CustomIcons = next
	return cloneDirectoryMarksSnapshot(s.snap), nil
}

func (s *visualDirectoryMarksSource) OpenFile(string) {}

func TestVisualDirectoryMarks(t *testing.T) {
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
				src := &visualDirectoryMarksSource{
					snap: DirectoryMarksSnapshot{
						HasWorkspace:        true,
						LocalConfigPath:     "/Users/demo/Library/Application Support/Lithe Desktop/workspace-directory-rules-a8f3c12e.json",
						SharedConfigEnabled: true,
						SharedConfigPath:    ".lithe/directories.json",
						ShowBgTint:          true,
						ShowTags:            true,
						GitIgnoreEnabled:    true,
						CustomTypes: []core.CustomDirectoryType{
							{
								ID:        "custom.core",
								Name:      "Core Business",
								Tag:       "core",
								Icon:      "icon.rocket",
								Color:     "#4e8df5",
								TintBg:    true,
								TintText:  true,
								InheritBg: true,
							},
							{
								ID:              "custom.legacy",
								Name:            "Legacy Archive",
								Tag:             "legacy",
								Icon:            "archive",
								Color:           "#8b949e",
								TintBg:          true,
								InheritBg:       true,
								ExcludeIndexing: true,
								ReadOnlyHint:    true,
								MatchGlob:       "legacy/**",
							},
						},
						CustomIcons: []core.CustomDirectoryIcon{
							{ID: "icon.rocket", Name: "Rocket", Path: "directory-icons/icon.rocket.svg"},
							{ID: "icon.shield", Name: "Shield", Path: "directory-icons/icon.shield.svg"},
						},
					},
				}
				w := newWindow(NewController(Options{
					DirectoryMarks: src,
					Text:           func() *i18n.Messages { return i18n.For(language) },
					Language:       func() i18n.Language { return language },
					SystemLanguage: language,
					SystemDark:     func() bool { return theme == "dark" },
				}), Values{Language: language.Code(), Theme: theme})
				w.sess.page = pageDirectoryMarks
				config := w.config()
				config.Width, config.Height = 1180, 960
				session, err := headless.Open(config, nil, headless.Options{})
				if err != nil {
					t.Fatal(err)
				}
				t.Cleanup(session.Close)
				d := &windowDriver{t: t, w: w, driver: session.Driver()}
				deadline := time.Now().Add(5 * time.Second)
				for !(w.dirMarksDraft.ready && !w.dirMarksDraft.busy) {
					if time.Now().After(deadline) {
						t.Fatal("timed out waiting for directory marks settings page to load")
					}
					d.pump()
					time.Sleep(10 * time.Millisecond)
				}
				w.dirMarksDraft.iconPickerOpen = false
				d.pump()
				d.pump()
				if err := session.Screenshot(filepath.Join(out, "directory-marks-"+language.Code()+"-"+theme+".png")); err != nil {
					t.Fatal(err)
				}
			})
		}
	}
}
