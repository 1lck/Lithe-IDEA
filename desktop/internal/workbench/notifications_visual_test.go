//go:build vivahead

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

func TestVisualNotificationsToolWindow(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0755); err != nil {
		t.Fatal(err)
	}
	scenes := []struct {
		theme, language, message, count string
	}{
		{"light", "zh-CN", "构建缓存即将用完，请检查磁盘空间。", "2 次"},
		{"dark", "en-US", "The build cache is nearly full. Check available disk space.", "2 times"},
	}
	for _, scene := range scenes {
		name := scene.theme + "-" + scene.language
		t.Run(name, func(t *testing.T) {
			prefs := store.At(t.TempDir())
			if err := prefs.Save(settingsFile, map[string]string{"theme": scene.theme}); err != nil {
				t.Fatal(err)
			}
			root := filepath.Join(t.TempDir(), "Demo")
			if err := os.Mkdir(root, 0700); err != nil {
				t.Fatal(err)
			}
			var session *headless.Session
			h := newHarnessWithDriver(t, Options{Kernel: &testKernel{Client: core.NewClient()}, Store: prefs, Languages: []string{scene.language}}, func(config app.Config) (*app.Driver, func(), error) {
				config.Width, config.Height = 1280, 800
				var err error
				session, err = headless.Open(config, nil, headless.Options{Scale: 1})
				if err != nil {
					return nil, nil, err
				}
				return session.Driver(), session.Close, nil
			})
			h.open(root)
			h.app.now = func() time.Time { return time.Date(2026, 1, 1, 10, 15, 0, 0, time.UTC) }
			h.app.notify(scene.message)
			h.app.notify(scene.message)
			h.app.overlay.toaster.Close(h.app.notifications.list[0].toast)
			h.app.invalidator.Invalidate()
			h.settle()
			h.click(center(h.button(itemNotifications)))
			h.settle()
			if err := session.Screenshot(filepath.Join(out, name+".png")); err != nil {
				t.Fatal(err)
			}
			if !h.showsWrapped(scene.message) || !h.shows(scene.count) {
				t.Fatal("the notification tool window did not paint the repeated message")
			}
		})
	}
}

func TestVisualSettingsRecoveryNotifications(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0o755); err != nil {
		t.Fatal(err)
	}
	system, err := app.NewDriver(app.Config{}, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(system.Close)
	for _, scene := range []struct {
		theme    themeChoice
		language string
	}{{"light", "en-US"}, {"dark", "zh-CN"}} {
		name := string(scene.theme) + "-" + scene.language
		t.Run(name, func(t *testing.T) {
			system.SetSystemAppearance(nativeAppearance(scene.theme))
			dir := t.TempDir()
			if err := os.WriteFile(filepath.Join(dir, settingsFile), []byte("{"), 0o600); err != nil {
				t.Fatal(err)
			}
			var session *headless.Session
			h := newHarnessWithDriver(t, Options{
				Kernel: &testKernel{Client: core.NewClient()}, Store: store.At(dir), Languages: []string{scene.language},
			}, func(config app.Config) (*app.Driver, func(), error) {
				config.Width, config.Height = 1438, 900
				var err error
				session, err = headless.Open(config, nil, headless.Options{Scale: 1})
				if err != nil {
					return nil, nil, err
				}
				return session.Driver(), session.Close, nil
			})
			capture := func(stage, titleKey string) {
				t.Helper()
				h.settle()
				if err := session.Resize(1439, 900); err != nil {
					t.Fatal(err)
				}
				if err := session.Resize(1440, 900); err != nil {
					t.Fatal(err)
				}
				if !h.shows(i18n.Shared(h.app.language(), titleKey)) {
					t.Fatalf("the %s notification did not paint", stage)
				}
				if err := session.Screenshot(filepath.Join(out, "settings-recovery-"+stage+"-"+name+".png")); err != nil {
					t.Fatal(err)
				}
			}
			capture("startup", "desktop.settings.unreadable.title")
			h.app.overlay.toaster.Close(h.app.notifications.list[0].toast)
			h.app.setTheme(scene.theme)
			capture("backup", "desktop.settings.backup.title")
		})
	}
}
