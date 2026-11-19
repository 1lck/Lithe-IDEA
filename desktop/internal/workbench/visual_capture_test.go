//go:build vivahead && lithevisual

package workbench

import (
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/localshell"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/headless"
)

// TestVisualGradleFileIcons captures Gradle scripts in the Project tree in both themes.
func TestVisualGradleFileIcons(t *testing.T) {
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
				root := t.TempDir()
				files := []string{"build.gradle", "build.gradle.kts", "build.gradle.tokens", "settings.gradle", "settings.gradle.kts"}
				writeTreeFiles(t, root, files...)
				prefs := store.At(t.TempDir())
				if err := prefs.Save(settingsFile, map[string]string{"theme": theme}); err != nil {
					t.Fatal(err)
				}
				var session *headless.Session
				h := newHarnessWithDriver(t, Options{Kernel: &testKernel{Client: core.NewClient()}, Store: prefs, Languages: []string{language}}, func(config app.Config) (*app.Driver, func(), error) {
					config.Width, config.Height = 1000, 640
					var err error
					session, err = headless.Open(config, nil, headless.Options{})
					if err != nil {
						return nil, nil, err
					}
					return session.Driver(), session.Close, nil
				})
				h.openTree(t, root)
				for _, name := range files {
					h.treeRowHit(name)
				}
				if err := session.Screenshot(filepath.Join(out, "gradle-file-icons-"+theme+"-"+language+".png")); err != nil {
					t.Fatal(err)
				}
			})
		}
	}
}

func TestVisualCompletionPopup(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, scene := range []struct {
		theme, language string
		width           int
	}{
		{"light", "en-US", 1000},
		{"dark", "zh-Hans", 1000},
		{"light", "zh-Hans", 350},
		{"dark", "en-US", 350},
	} {
		t.Run(scene.theme+"-"+scene.language, func(t *testing.T) {
			prefs := store.At(t.TempDir())
			if err := prefs.Save(settingsFile, map[string]string{"theme": scene.theme}); err != nil {
				t.Fatal(err)
			}
			kernel := &semanticTestKernel{testKernel: &testKernel{Client: core.NewClient()}}
			var session *headless.Session
			h := newHarnessWithDriver(t, Options{Kernel: kernel, Store: prefs, Languages: []string{scene.language}}, func(config app.Config) (*app.Driver, func(), error) {
				config.Width, config.Height = scene.width, 600
				config.MinWidth = min(config.MinWidth, scene.width)
				var err error
				session, err = headless.Open(config, nil, headless.Options{})
				if err != nil {
					return nil, nil, err
				}
				return session.Driver(), session.Close, nil
			})
			f := openSemanticFixture(t, h, kernel)
			f.openFunctionCompletions(t)
			if err := h.driver.Key(gfx.KeyDown, 0); err != nil {
				t.Fatal(err)
			}
			if err := session.Screenshot(filepath.Join(out, "completion-"+scene.theme+"-"+scene.language+".png")); err != nil {
				t.Fatal(err)
			}
		})
	}
}

// TestVisualWorkbench uses the archive's repository in a private temporary checkout.
// No installed plugins, user settings, native windows or network services are used.
func TestVisualWorkbench(t *testing.T) {
	out, reference := os.Getenv("LITHE_VISUAL_OUTPUT_DIR"), os.Getenv("LITHE_VISUAL_BASELINE_DIR")
	if out == "" || reference == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR and LITHE_VISUAL_BASELINE_DIR")
	}
	if err := os.MkdirAll(out, 0755); err != nil {
		t.Fatal(err)
	}
	for _, theme := range []string{"dark", "light"} {
		t.Run(theme, func(t *testing.T) {
			requireTestGit(t)
			root := filepath.Join(t.TempDir(), "BaselineDemo")
			gitRun(t, t.TempDir(), "clone", filepath.Join(reference, "fixture-history.bundle"), root)
			fixtures := os.DirFS(filepath.Join(reference, "fixture-working-tree"))
			err := fs.WalkDir(fixtures, ".", func(path string, entry fs.DirEntry, err error) error {
				if err != nil {
					return err
				}
				if entry.IsDir() {
					return os.MkdirAll(filepath.Join(root, path), 0700)
				}
				data, err := fs.ReadFile(fixtures, path)
				if err != nil {
					return err
				}
				return os.WriteFile(filepath.Join(root, path), data, 0600)
			})
			if err != nil {
				t.Fatal(err)
			}
			gitRun(t, root, "add", "notes.txt")

			scenes := []struct {
				id, tool string
				docs     int
			}{
				{"01-welcome-empty", "", -1}, {"02-new-empty-project", "", -1}, {"03-welcome-more-menu", "", -1}, {"04-clone-repository", "", -1},
				{"40-workbench-empty", "", 0}, {"41-editor-project", "", 1}, {"42-editor-tabs", "", 2},
				{"50-git-log", itemGit, 2}, {"52-git-worktrees", itemGit, 2}, {"53-git-console", itemGit, 2},
				{"54-git-commit", itemCommit, 2}, {"61-problems", itemProblems, 2}, {"62-run-empty", itemRun, 2},
				{"63-tests-empty", itemTests, 2}, {"64-debug-empty", itemDebug, 2}, {"55-branch-popup", "", 2},
				{"73-project-switcher", "", 2}, {"68-run-config-picker", "", 2}, {"65-project-search", itemFind, 2},
				{"66-project-replace", itemFind, 2}, {"67-search-everywhere", "", 2}, {"m19-goto-line-dialog", "", 2},
				{"56-diff-split", itemCommit, 2}, {"57-diff-unified", itemCommit, 2}, {"m47-diff-settings", itemCommit, 2},
				{"69-encoding-menu", "", 2}, {"71-workbench-gear-menu", "", 2},
				{"51-git-user-filter", itemGit, 2}, {"m07-git-tool-actions", itemGit, 2}, {"m09-git-date-filter", itemGit, 2},
				{"m10-git-path-filter", itemGit, 2}, {"m11-git-branch-filter", itemGit, 2},
				{"m02-directory-new-submenu", "", 2}, {"m13-tool-window-move-submenu", "", 2}, {"m17-editor-tab-copy-path", "", 2}, {"m50-git-tracking-branch-submenu", itemGit, 2}, {"m44-git-change-context", itemCommit, 2},
				{"m06-branch-popup", "", 2}, {"m20-language-service-menu", "", 2},
				{"m01-directory-context", "", 2}, {"m04-project-root-context", "", 2},
				{"m12-tool-window-context", "", 2}, {"m16-editor-tab-single-context", "", 1},
				{"m18-editor-tab-multiple-context", "", 2}, {"m22-rename-dialog", "", 2}, {"m23-new-file-dialog", "", 2},
				{"m27-editor-content-context", "", 2}, {"m48-git-local-branch-context", itemGit, 2},
				{"m49-git-commit-context", itemGit, 2}, {"60-terminal", itemTerminal, 2}, {"m14-terminal-actions", itemTerminal, 2}, {"m15-terminal-shell-menu", itemTerminal, 2},
			}
			for _, scene := range scenes {
				t.Run(scene.id, func(t *testing.T) {
					prefs := store.At(t.TempDir())
					if err := prefs.Save(settingsFile, map[string]string{"theme": theme}); err != nil {
						t.Fatal(err)
					}
					var session *headless.Session
					h := newHarnessWithDriver(t, Options{Kernel: gitKernel{core.NewClient()}, Store: prefs, Languages: []string{"zh-Hans"}, Version: "0.1.0"}, func(config app.Config) (*app.Driver, func(), error) {
						config.Width, config.Height = 1440, 871
						if scene.docs < 0 {
							config.Width, config.Height = 800, 682
							config.MinWidth = 800
						}
						var err error
						session, err = headless.Open(config, nil, headless.Options{})
						if err != nil {
							return nil, nil, err
						}
						return session.Driver(), session.Close, nil
					})
					var p *project
					if scene.docs >= 0 {
						p = h.openTree(t, root)
						for s, index := range h.app.chrome.open {
							if index >= 0 && h.app.chrome.catalog[index].id != itemProject {
								h.app.hidePanel(slot(s))
							}
						}
						h.settleChain()
						for _, file := range []string{"src/main.swift", "src/config.json"}[:scene.docs] {
							h.app.openFile(p, filepath.Join(root, file))
							h.settleChain()
						}
						if scene.tool != "" {
							h.click(center(h.button(scene.tool)))
							h.settleChain()
						}
					}
					switch scene.id {
					case "56-diff-split", "57-diff-unified", "m47-diff-settings":
						diff := openDiffTab(t, h, p, "notes.txt")
						h.app.setDiffMode(p, diff, scene.id != "57-diff-unified", diff.whole)
						h.settleChain()
						if scene.id == "m47-diff-settings" {
							h.clickNamed(h.shared("native.diffSettings"))
						}
					case "m06-branch-popup":
						h.app.openBranches()
					case "m20-language-service-menu":
						h.click(center(h.button(itemLSP)))
					case "51-git-user-filter":
						h.clickNamed(h.app.text.Git.FilterUser)
					case "m07-git-tool-actions":
						h.clickNamed(h.app.text.Git.Actions)
					case "m09-git-date-filter":
						h.clickNamed(h.app.text.Git.FilterDate)
					case "m10-git-path-filter":
						h.clickNamed(h.app.text.Git.FilterPaths)
					case "m11-git-branch-filter":
						h.clickNamed(h.app.text.Git.FilterBranch)
					case "m02-directory-new-submenu":
						h.rightClickNamed("src")
						h.clickNamed(h.shared("native.new"))
					case "m13-tool-window-move-submenu":
						h.rightClickAt(h.button(itemProject))
						h.clickNamed(h.shared("desktop.tools.moveTo"))
					case "m17-editor-tab-copy-path":
						h.rightClickAt(h.tabHit("config.json"))
						h.clickNamed(h.shared("native.copyPathReference"))
					case "m50-git-tracking-branch-submenu":
						h.logRefMenu("main")
						h.clickNamed(h.shared("native.trackingBranch"))
					case "m44-git-change-context":
						h.rightClickNamed("notes.txt")
					case "m01-directory-context":
						h.rightClickNamed("src")
					case "m04-project-root-context":
						h.rightClickNamed("BaselineDemo")
					case "m12-tool-window-context":
						h.rightClickAt(h.button(itemProject))
					case "m16-editor-tab-single-context":
						h.rightClickAt(h.tabHit("main.swift"))
					case "m18-editor-tab-multiple-context":
						h.rightClickAt(h.tabHit("config.json"))
					case "m22-rename-dialog":
						h.rightClickNamed("README.txt")
						h.clickNamed(h.shared("desktop.files.rename"))
					case "m23-new-file-dialog":
						h.rightClickNamed("BaselineDemo")
						h.clickNamed(h.shared("native.new"))
						h.clickNamed(h.shared("desktop.files.newFile"))
					case "m27-editor-content-context":
						d := p.selectedDocument(p.docs.group)
						h.rightClickAt(h.topHit(d.hit))
					case "m48-git-local-branch-context":
						h.logRefMenu("main")
					case "m49-git-commit-context":
						h.rightClickNamed("Document visual baseline workflow")
					case "60-terminal", "m14-terminal-actions", "m15-terminal-shell-menu":
						term := busyTerminal(t, h, "printf 'Lithe terminal visual baseline\\n'; read line")
						h.await("terminal output", func() bool { return strings.Contains(term.view.RetainedText(4096), "visual baseline") })
						h.settleChain()
						if scene.id == "m14-terminal-actions" {
							h.rightClickAt(h.topHit(term.hit))
						}
						if scene.id == "m15-terminal-shell-menu" {
							h.app.listShells = func() []localshell.Choice {
								return []localshell.Choice{{Name: "zsh", Path: "/bin/zsh", Default: true}, {Name: "bash", Path: "/bin/bash"}}
							}
							h.clickNamed(h.app.text.Terminal.ShellMenu)
						}
					case "02-new-empty-project":
						h.openNewProjectSheet()
					case "03-welcome-more-menu":
						h.clickNamed(i18n.Shared(h.app.language(), "desktop.clone.more"))
					case "04-clone-repository":
						h.clickNamed(h.shared("desktop.clone.more"))
						h.clickNamed(h.shared("desktop.clone.title"))
					case "52-git-worktrees":
						h.clickNamed(h.app.text.Git.Worktrees)
					case "53-git-console":
						h.clickNamed(h.app.text.Git.Console)
					case "55-branch-popup":
						h.app.openBranches()
					case "73-project-switcher":
						h.clickNamed(h.app.text.Title.ProjectMenu)
					case "68-run-config-picker":
						h.click(center(h.button(itemRunConfig)))
					case "65-project-search":
						h.app.openFindInFiles(p, false)
						h.app.searchView.query.SetText("greet")
					case "66-project-replace":
						h.app.openFindInFiles(p, true)
						h.app.searchView.query.SetText("greet")
					case "67-search-everywhere":
						h.app.everywhereView.delay = 0
						h.app.openEverywhere(p)
						h.app.everywhereView.query.SetText("main")
					case "m19-goto-line-dialog":
						h.click(center(h.button(itemCaret)))
					case "69-encoding-menu":
						h.click(center(h.button(itemEncoding)))
					case "71-workbench-gear-menu":
						h.click(center(h.button(itemTitleSettings)))
					}
					h.settleChain()
					if scene.id == "65-project-search" || scene.id == "66-project-replace" {
						if err := h.driver.Click(center(h.hit(searchQueryID)).X, center(h.hit(searchQueryID)).Y); err != nil {
							t.Fatal(err)
						}
						if _, err := h.driver.ShortcutChord(primaryModifier(), 'a'); err != nil {
							t.Fatal(err)
						}
						if err := h.driver.Type("greet"); err != nil {
							t.Fatal(err)
						}
						h.await("search result rows", func() bool { return !p.search.loading && len(p.search.matches) > 0 })
					}
					if scene.id == "67-search-everywhere" {
						h.await("global search result rows", func() bool { return !p.everywhere.loading && len(p.everywhere.matches) > 0 })
					}
					// Every transient scene must prove the requested surface was painted.
					// Mutating state without input can leave the driver's last frame unchanged.
					visible := ""
					switch scene.id {
					case "m19-goto-line-dialog":
						visible = h.shared("desktop.navigation.title")
					case "m22-rename-dialog":
						visible = h.shared("desktop.files.renameTitle")
					case "m23-new-file-dialog":
						visible = h.shared("desktop.files.newFileTitle")
					case "69-encoding-menu":
						visible = h.shared("desktop.encoding.reopen")
					case "71-workbench-gear-menu":
						visible = h.app.text.Title.Preferences
					case "73-project-switcher":
						visible = h.app.text.Title.OpenProjects
					case "68-run-config-picker":
						visible = h.shared("native.editConfiguration")
					case "m07-git-tool-actions":
						visible = h.app.text.Git.FetchAll
					case "m09-git-date-filter":
						visible = h.app.text.Git.Last7Days
					case "m10-git-path-filter":
						visible = h.app.text.Git.FilterPaths
					case "m11-git-branch-filter":
						visible = h.app.text.Git.AllReferences
					case "m15-terminal-shell-menu":
						visible = h.app.text.Terminal.Settings
					case "04-clone-repository":
						visible = h.shared("desktop.clone.title")
					}
					if visible != "" && !h.shows(visible) {
						if err := session.Screenshot(filepath.Join(out, "failed-"+scene.id+"-"+theme+".png")); err != nil {
							t.Logf("capture failed scene: %v", err)
						}
						t.Fatalf("visual scene %s did not paint %q; shell menu state: %+v", scene.id, visible, h.app.term.shells)
					}
					if err := session.Screenshot(filepath.Join(out, scene.id+"-"+theme+".png")); err != nil {
						t.Fatal(err)
					}
				})
			}
		})
	}
}

// The project's gradient belongs behind the solid editor/tool islands. An absolute
// background child is painted after normal siblings and incorrectly tints them.
func TestVisualWorkbenchGradientStaysBehindPanels(t *testing.T) {
	var session *headless.Session
	prefs := store.At(t.TempDir())
	if err := prefs.Save(settingsFile, map[string]string{"theme": "dark"}); err != nil {
		t.Fatal(err)
	}
	h := newHarnessWithDriver(t, Options{Kernel: &testKernel{Client: core.NewClient()}, Store: prefs, Languages: []string{"en-US"}}, func(config app.Config) (*app.Driver, func(), error) {
		var err error
		session, err = headless.Open(config, nil, headless.Options{Scale: 1})
		if err != nil {
			return nil, nil, err
		}
		return session.Driver(), session.Close, nil
	})
	h.openTree(t, t.TempDir())
	h.settleChain()
	picture, err := session.Image()
	if err != nil {
		t.Fatal(err)
	}
	got := picture.RGBAAt(150, 280)
	if got.R != 25 || got.G != 26 || got.B != 28 {
		t.Fatalf("project gradient covered the opaque tool panel: %v, want #191a1c", got)
	}
}

// TestVisualNewProjectFieldDescriptions captures a generator form whose fields describe
// themselves: each description is the tip of an ⓘ beside its field, shown here resting
// on the first one. It needs only LITHE_VISUAL_OUTPUT_DIR.
func TestVisualNewProjectFieldDescriptions(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0755); err != nil {
		t.Fatal(err)
	}
	for _, theme := range []string{"dark", "light"} {
		for _, language := range []string{"zh-Hans", "en-US"} {
			t.Run(theme+"-"+language, func(t *testing.T) {
				var session *headless.Session
				prefs := store.At(t.TempDir())
				if err := prefs.Save(settingsFile, map[string]string{"theme": theme}); err != nil {
					t.Fatal(err)
				}
				h := newHarnessWithDriver(t, Options{Kernel: &testKernel{Client: core.NewClient()}, Store: prefs, Languages: []string{language}}, func(config app.Config) (*app.Driver, func(), error) {
					config.Width, config.Height = 800, 682
					config.MinWidth = 800
					var err error
					session, err = headless.Open(config, nil, headless.Options{})
					if err != nil {
						return nil, nil, err
					}
					return session.Driver(), session.Close, nil
				})
				h.offerGenerators(describedGeneratorPlugin(t))
				h.openNewProjectSheet()
				h.chooseGenerator("Described", "dev.lithe.test.described/described")
				more := i18n.Shared(h.app.language(), "native.moreInformation")
				hovered := false
				for _, hit := range h.driver.Snapshot().Hits {
					if hit.Label == more && !hit.IsLabel {
						at := center(hit.Bounds)
						if err := h.driver.Move(at.X, at.Y); err != nil {
							t.Fatal(err)
						}
						h.settle()
						hovered = true
						break
					}
				}
				if !hovered {
					t.Fatal("the form has no ⓘ")
				}
				if tips := h.tooltips(); len(tips) != 1 || tips[0].Value != "The flavor the project starts from." {
					t.Fatalf("resting on the first ⓘ shows the tips %+v", tips)
				}
				if err := session.Screenshot(filepath.Join(out, "new-project-field-info-"+theme+"-"+language+".png")); err != nil {
					t.Fatal(err)
				}
			})
		}
	}
}

// TestVisualNewProjectAdvancedSettings captures a generator form with its
// "Advanced Settings" group closed and open, so the chevron of each state shows.
// It needs only LITHE_VISUAL_OUTPUT_DIR.
func TestVisualNewProjectAdvancedSettings(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0755); err != nil {
		t.Fatal(err)
	}
	for _, theme := range []string{"dark", "light"} {
		for _, language := range []string{"zh-Hans", "en-US"} {
			t.Run(theme+"-"+language, func(t *testing.T) {
				var session *headless.Session
				prefs := store.At(t.TempDir())
				if err := prefs.Save(settingsFile, map[string]string{"theme": theme}); err != nil {
					t.Fatal(err)
				}
				h := newHarnessWithDriver(t, Options{Kernel: &testKernel{Client: core.NewClient()}, Store: prefs, Languages: []string{language}}, func(config app.Config) (*app.Driver, func(), error) {
					config.Width, config.Height = 800, 682
					config.MinWidth = 800
					var err error
					session, err = headless.Open(config, nil, headless.Options{})
					if err != nil {
						return nil, nil, err
					}
					return session.Driver(), session.Close, nil
				})
				h.offerGenerators(advancedGeneratorPlugin(t))
				h.openNewProjectSheet()
				h.chooseGenerator("Tuned", "dev.lithe.test.advanced/tuned")
				advanced := i18n.Shared(h.app.language(), "desktop.newProject.advanced")
				for _, state := range []string{"closed", "open"} {
					if state == "open" {
						h.clickNamed(advanced)
						h.await("the advanced field", func() bool { return h.shows("Level") })
					}
					if err := session.Screenshot(filepath.Join(out, "new-project-advanced-"+state+"-"+theme+"-"+language+".png")); err != nil {
						t.Fatal(err)
					}
				}
			})
		}
	}
}

// TestVisualDebugAnnouncedAdapterExitedFirst captures the debug view after a synthetic
// tcpAnnounced adapter exited before it announced its port: the session ends and the
// view shows why. It needs only LITHE_VISUAL_OUTPUT_DIR.
func TestVisualDebugAnnouncedAdapterExitedFirst(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0755); err != nil {
		t.Fatal(err)
	}
	for _, theme := range []string{"dark", "light"} {
		for _, language := range []string{"zh-Hans", "en-US"} {
			t.Run(theme+"-"+language, func(t *testing.T) {
				var session *headless.Session
				options := debugPluginOptions(t, "dev.lithe.test.debug-announced", debugAnnouncedManifest, true, &testKernel{Client: core.NewClient()}, theme)
				options.Languages = []string{language}
				h := newHarnessWithDriver(t, options, func(config app.Config) (*app.Driver, func(), error) {
					config.Width, config.Height = 1200, 760
					var err error
					session, err = headless.Open(config, nil, headless.Options{})
					if err != nil {
						return nil, nil, err
					}
					return session.Driver(), session.Close, nil
				})
				root, _, watch := announcedWorkspace(t, "exit")
				p := openHostedPanel(t, h, root)
				h.clickNamed(h.app.text.Debug.Start)
				awaitStateWithin(t, h, 20*time.Second, "the failure", func() bool { return p.debug.failure != "" })
				if p.debug.failure != h.app.text.Debug.NotAnnounced {
					t.Fatalf("failure = %q, want the missing announcement", p.debug.failure)
				}
				watch.ended(t, 20*time.Second)
				// The pointer leaves the start button so its tip does not cover the reason.
				if err := h.driver.Move(800, 150); err != nil {
					t.Fatal(err)
				}
				h.settle()
				if tips := h.tooltips(); len(tips) != 0 {
					t.Fatalf("tips still shown: %+v", tips)
				}
				if err := session.Screenshot(filepath.Join(out, "debug-announced-exited-"+theme+"-"+language+".png")); err != nil {
					t.Fatal(err)
				}
			})
		}
	}
}

// TestVisualRowMenuPastTheName captures the context menu of a project tree row and of a Git
// reference row, each opened by a right-click on the empty part of the row past its name: the
// name labels its row, so the whole row carries the menu. It needs only LITHE_VISUAL_OUTPUT_DIR.
func TestVisualRowMenuPastTheName(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0755); err != nil {
		t.Fatal(err)
	}
	// rightClickPastTheName right-clicks row near its right end, well past the name it starts
	// with.
	rightClickPastTheName := func(h *harness, row gfx.Rect) {
		t.Helper()
		if err := h.driver.ClickButton(row.X+row.Width-24, row.Y+row.Height/2, gfx.PointerButtonSecondary); err != nil {
			t.Fatal(err)
		}
		h.settle()
	}
	for _, theme := range []string{"dark", "light"} {
		for _, language := range []string{"zh-Hans", "en-US"} {
			open := func(t *testing.T, kernel Kernel) (*harness, *headless.Session) {
				var session *headless.Session
				prefs := store.At(t.TempDir())
				if err := prefs.Save(settingsFile, map[string]string{"theme": theme}); err != nil {
					t.Fatal(err)
				}
				h := newHarnessWithDriver(t, Options{Kernel: kernel, Store: prefs, Languages: []string{language}}, func(config app.Config) (*app.Driver, func(), error) {
					config.Width, config.Height = 1000, 640
					var err error
					session, err = headless.Open(config, nil, headless.Options{})
					if err != nil {
						return nil, nil, err
					}
					return session.Driver(), session.Close, nil
				})
				return h, session
			}
			t.Run("tree-"+theme+"-"+language, func(t *testing.T) {
				root := t.TempDir()
				writeTreeFiles(t, root, "src/main.txt", "notes.txt", "readme.txt")
				h, session := open(t, &testKernel{Client: core.NewClient()})
				h.openTree(t, root)
				rightClickPastTheName(h, h.treeRowHit("notes.txt").Bounds)
				if !h.hasPopupItem(h.shared("desktop.files.delete")) {
					t.Fatal("the right-click past the name of notes.txt opened no menu")
				}
				if err := session.Screenshot(filepath.Join(out, "tree-row-menu-past-name-"+theme+"-"+language+".png")); err != nil {
					t.Fatal(err)
				}
			})
			t.Run("gitlog-"+theme+"-"+language, func(t *testing.T) {
				dir := newTestRepository(t)
				gitRun(t, dir, "branch", "topic")
				h, session := open(t, gitKernel{core.NewClient()})
				h.openLog(t, dir)
				v := &h.app.logView
				i := slices.IndexFunc(v.refItems, func(r logRefRow) bool { return r.kind == logRefReference && r.short == "topic" })
				if i < 0 {
					t.Fatal("the reference pane shows no row of topic")
				}
				rightClickPastTheName(h, h.topHit(v.refs.RowID(i)))
				if item := h.app.text.Branch.NewBranchFrom("topic"); !h.hasPopupItem(item) {
					t.Fatal("the right-click past the name of topic opened no menu")
				}
				if err := session.Screenshot(filepath.Join(out, "gitlog-ref-menu-past-name-"+theme+"-"+language+".png")); err != nil {
					t.Fatal(err)
				}
			})
		}
	}
}
