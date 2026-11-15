//go:build vivahead

package workbench

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/buildinfo"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/settingswindow"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/headless"
	appupdate "github.com/vivaui/viva/update"
)

// visualUpdateNotes are the notes the captures show, in the language of the scene. Release
// notes are written by whoever publishes the version, not translated by the window.
var visualUpdateNotes = map[string]string{
	"zh-CN": "## 新功能\n\n- 更新面板支持 AutoBuild 与正式版两个渠道，每个渠道可以单独设置更新源\n" +
		"- 标题栏右上角新增绿色下载箭头，先看更新内容，再决定下载、跳过或稍后\n\n" +
		"## 修复\n\n- 设置文件保存时不再丢弃旧版本不认识的配置项（[#1913](https://github.com/1lck/Lithe-IDEA/issues/1913)）\n" +
		"- 增量更新失败时自动改为下载完整安装包\n- 切换渠道时可以选择恢复上次离开该渠道时的设置\n",
	"en-US": "## New\n\n- Updates come from two channels, AutoBuild and Stable, each with its own feed\n" +
		"- A green arrow at the top right of the title bar shows what changed before you download, skip or wait\n\n" +
		"## Fixed\n\n- Saving settings no longer drops entries an older version does not know ([#1913](https://github.com/1lck/Lithe-IDEA/issues/1913))\n" +
		"- A patch that cannot be applied falls back to the full archive\n- Switching channel can bring back the settings you had there\n",
}

// TestVisualUpdateDialog captures the update arrow and dialog: on the start screen and on a
// project's title bar, the dialog with what 0.8.0 changes and how much it downloads, while it
// downloads, once it is ready, and offering AutoBuild's build to a stable installation.
func TestVisualUpdateDialog(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0755); err != nil {
		t.Fatal(err)
	}
	for _, scene := range []struct{ theme, language string }{{"dark", "zh-CN"}, {"light", "en-US"}} {
		for _, state := range []string{"welcome", "available", "downloading", "ready", "autobuild"} {
			name := "updates-" + state + "-" + scene.theme + "-" + scene.language
			t.Run(name, func(t *testing.T) {
				h, session := visualUpdateHarness(t, scene.theme, scene.language, state)
				a := h.app
				if state != "welcome" {
					a.showUpdateDialog(surfaceToolbar)
				}
				switch state {
				case "downloading":
					saved := updateCacheDir
					cache := t.TempDir()
					updateCacheDir = func() (string, error) { return cache, nil }
					t.Cleanup(func() { updateCacheDir = saved })
					a.updateNow()
					// The held download reports a quarter first; the capture shows more of it.
					h.await("the download", func() bool { s := a.updateStatus(); return s.Downloading && s.Progress > 0 })
					a.changeUpdate(func(s *settingswindow.UpdateStatus) { s.Progress = 0.62 })
				case "ready":
					a.changeUpdate(func(s *settingswindow.UpdateStatus) { s.Ready = true })
				}
				h.settle()
				if err := session.Screenshot(filepath.Join(out, name+".png")); err != nil {
					t.Fatal(err)
				}
			})
		}
	}
}

// visualUpdateHarness is a 1280×800 window of a stable 0.7.0 build in theme and language that
// found 0.8.0 with a patch from 0.7.0, or for autobuild switched to AutoBuild and found its
// build; it shows the start screen for welcome and an open project otherwise.
func visualUpdateHarness(t *testing.T, theme, language, state string) (*harness, *headless.Session) {
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
	a := h.app
	a.version = "0.7.0"
	stable := visualFeed("0.8.0", "https://github.com/1lck/Lithe-IDEA/releases/tag/desktop-v0.8.0")
	stable.Latest.Assets[0].Patches = []appupdate.Patch{{
		FromVersion: "0.7.0", URL: "https://example.invalid/lithe.patch", Size: 3_400_000, SHA256: stable.Latest.Assets[0].SHA256,
	}}
	feeds := &channelFeeds{sources: map[string]*fakeUpdateSource{
		buildinfo.ChannelStable:    {feed: stable},
		buildinfo.ChannelAutoBuild: {feed: visualFeed("0.8.0-autobuild.20261116093000", "")},
	}}
	openUpdateSource(h, buildinfo.ChannelStable, feeds.open)
	notes := visualUpdateNotes[language]
	replaceUpdateNotes(t, func(_ context.Context, address string, _ int64) ([]byte, error) {
		version := "0.8.0"
		if filepath.Base(address) == "autobuild.notes.md" {
			version = "0.8.0-autobuild.20261116093000"
		}
		return []byte(updateNotesHeader + version + " -->\n" + notes), nil
	})
	t.Cleanup(a.stopUpdates)
	if state != "welcome" {
		root := filepath.Join(t.TempDir(), "Demo")
		if err := os.Mkdir(root, 0700); err != nil {
			t.Fatal(err)
		}
		h.open(root)
	}
	if state == "autobuild" {
		a.setUpdateChannel(buildinfo.ChannelAutoBuild, false, false)
	} else {
		a.checkForUpdates(true)
	}
	h.await("the version and its notes", func() bool {
		s := a.updateStatus()
		return s.Available != "" && s.Notes != ""
	})
	return h, session
}

// visualFeed is a feed offering version as a 96 MB archive for this platform.
func visualFeed(version, notesURL string) *appupdate.Feed {
	feed := updateFeed(version)
	feed.Latest.NotesURL = notesURL
	feed.Latest.Assets[0].Size = 96_000_000
	return feed
}
