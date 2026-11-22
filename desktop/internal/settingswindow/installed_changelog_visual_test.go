//go:build vivahead && lithevisual

package settingswindow

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/headless"
)

// TestVisualInstalledChangelog renders the Changelog tab of one marketplace plugin with a
// pre-release, the installed release and an older one, their notes in headings, lists, code
// and links. Opt in with -tags 'vivahead lithevisual' and LITHE_VISUAL_OUTPUT_DIR.
func TestVisualInstalledChangelog(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR to capture the Changelog tab")
	}
	if err := os.MkdirAll(out, 0755); err != nil {
		t.Fatal(err)
	}
	for _, look := range []struct {
		theme    string
		language i18n.Language
		notes    [3]string
	}{
		{"dark", i18n.Chinese, [3]string{
			"试用新的设置布局，欢迎反馈。",
			"### 新功能\n\n- 设置页显示实际生效的命令，例如 `fixture build --release`\n- 新增两个构建选项\n\n### 修复\n\n- 刷新插件索引后立即看到新版本，见 [说明](https://example.com/guide)",
			"首个版本。",
		}},
		{"light", i18n.English, [3]string{
			"Tries the new settings layout; feedback welcome.",
			"### Features\n\n- The settings show the command that runs, such as `fixture build --release`\n- Two new build options\n\n### Fixes\n\n- A refreshed index shows the new version at once, see [the guide](https://example.com/guide)",
			"The first release.",
		}},
	} {
		t.Run(look.theme, func(t *testing.T) {
			releases := fixtureReleases()
			for i := range releases {
				releases[i].Notes = look.notes[i]
			}
			releases[1].Name = ""
			w, _, _ := detailFixture(look.language, func(opts *Options) {
				opts.PluginReleases = func(context.Context, string) ([]PluginRelease, bool, error) {
					return releases, true, nil
				}
			})
			w.sess.values.Theme = look.theme
			w.installed.tab = installedChangelog
			config := w.config()
			config.Width, config.Height = 1100, 720
			session, err := headless.Open(config, nil, headless.Options{})
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(session.Close)
			d := &windowDriver{t: t, w: w, driver: session.Driver()}
			d.until("the releases", func() bool { _, ok := d.painted("v1.2.3"); return ok })
			// The spinner of the read that just finished stops on the next frame.
			time.Sleep(20 * time.Millisecond)
			w.inv.Invalidate()
			d.pump()
			if err := session.Screenshot(filepath.Join(out, "installed-changelog-"+look.theme+".png")); err != nil {
				t.Fatal(err)
			}
		})
	}
}
