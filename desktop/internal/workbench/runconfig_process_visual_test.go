//go:build vivahead && lithevisual

package workbench

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/localshell"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/headless"
)

// TestVisualBuiltInProcessRuns captures the built-in runs of a project without any plugin in
// the Run/Debug Configurations dialog: the dialog with nothing yet, the editor of a shell
// script with a script file and with script text, its interpreter list of the terminal's shells
// and its custom interpreter field, the Run window after the script ran, the +
// menu of every kind, the editors of a PowerShell script, an executable and a batch script
// this platform cannot run, the title bar with that batch script chosen, the shell script in a
// folder of the unsorted list, that folder's pane, a copy of the executable, and the title bar's
// run menu marking that batch script and naming a run configuration file that was not read. The
// script runs under the system's shell. It needs only LITHE_VISUAL_OUTPUT_DIR; the dark captures are in Chinese and the light ones in English.
func TestVisualBuiltInProcessRuns(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0755); err != nil {
		t.Fatal(err)
	}
	for _, look := range []struct{ theme, language string }{{"dark", "zh-Hans"}, {"light", "en-US"}} {
		theme, language := look.theme, look.language
		{
			t.Run(theme, func(t *testing.T) {
				temporary := t.TempDir()
				for _, variable := range []string{"TMPDIR", "TMP", "TEMP"} {
					t.Setenv(variable, temporary)
				}
				root := filepath.Join(t.TempDir(), "ScriptDemo")
				files := map[string]string{
					"scripts/greet.sh":  "#!/bin/bash\necho \"$GREETING from $1\"\n",
					"scripts/clean.ps1": "Remove-Item -Recurse build\n",
					"bin/README.md":     "Tools built here.\n",
					"bin/tool":          "#!/bin/sh\n",
				}
				for name, text := range files {
					path := filepath.Join(root, filepath.FromSlash(name))
					if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
						t.Fatal(err)
					}
					if err := os.WriteFile(path, []byte(text), 0o644); err != nil {
						t.Fatal(err)
					}
				}
				prefs := store.At(t.TempDir())
				if err := prefs.Save(settingsFile, map[string]string{"theme": theme}); err != nil {
					t.Fatal(err)
				}
				var session *headless.Session
				h := newHarnessWithDriver(t, Options{Kernel: &testKernel{Client: core.NewClient()}, Store: prefs, Languages: []string{language}}, func(config app.Config) (*app.Driver, func(), error) {
					config.Width, config.Height = 1200, 760
					var err error
					session, err = headless.Open(config, nil, headless.Options{})
					if err != nil {
						return nil, nil, err
					}
					return session.Driver(), session.Close, nil
				})
				shot := func(scene string) {
					t.Helper()
					h.settleChain()
					if err := session.Screenshot(filepath.Join(out, "builtin-run-"+scene+"-"+theme+".png")); err != nil {
						t.Fatal(err)
					}
				}
				// The interpreter lists show the same shells on every machine.
				h.app.listShells = func() []localshell.Choice {
					return []localshell.Choice{{Name: "zsh", Path: "/bin/zsh", Default: true}, {Name: "bash", Path: "/bin/bash"}, {Name: "pwsh", Path: "/usr/local/bin/pwsh"}}
				}
				p := h.openTree(t, root)
				h.app.post(func(a *App) { a.refreshRunConfigurations(p) })
				awaitStateWithin(t, h, 10*time.Second, "the run kinds", func() bool {
					s := &p.runConfigs
					return s.generation > 0 && !s.loading && s.types != nil
				})
				d := &p.runConfigs.dialog
				// edit adds a new run of provider to the open dialog as its + menu does, sets the
				// texts and checkboxes given, and waits for the fields that follow the edit.
				edit := func(provider string, texts map[string]string, flags map[string]bool, variables ...*runConfigVariable) *runConfigForm {
					t.Helper()
					var f *runConfigForm
					h.app.post(func(a *App) {
						a.addRunConfigDraft(p, builtInKind(provider), nil)
						f = d.drafts[d.selected].form
					})
					awaitStateWithin(t, h, 10*time.Second, "the editor of "+provider, func() bool {
						return f != nil && f.open && !f.loading && f.fields != nil
					})
					h.app.post(func(a *App) {
						for id, value := range texts {
							if text := f.texts[id]; text != nil {
								*text = value
							}
						}
						for id, value := range flags {
							if flag := f.flags[id]; flag != nil {
								*flag = value
							}
						}
						f.environment = append(f.environment, variables...)
						a.runConfigFormEdited(p, f)
					})
					awaitStateWithin(t, h, 10*time.Second, "the edited editor", func() bool { return !f.refreshing })
					return f
				}
				// apply presses step and waits for the dialog to close.
				apply := func(step runConfigDialogStep) {
					t.Helper()
					pressed := false
					h.app.post(func(a *App) {
						a.applyRunConfigDialog(p, step)
						pressed = true
					})
					awaitStateWithin(t, h, 10*time.Second, "the save", func() bool { return pressed && (!d.open || !d.saving) })
					if d.open {
						t.Fatalf("the dialog stayed open: failure %q", d.failure)
					}
				}

				h.app.post(func(a *App) { a.openRunConfigDialog(p, "") })
				shot("dialog-empty")

				f := edit(runProviderShell, map[string]string{"name": "Greet", "source": "file", "script": "scripts/greet.sh", "scriptOptions": "Lithe", "workingDirectory": "scripts"},
					map[string]bool{"storeAsProjectFile": true}, &runConfigVariable{name: "GREETING", value: "Hello"})
				shot("shell-file")

				h.app.post(func(a *App) {
					*f.texts["source"] = "text"
					a.runConfigFormEdited(p, f)
				})
				awaitStateWithin(t, h, 10*time.Second, "the script text field", func() bool { return !f.refreshing && f.texts["text"] != nil })
				h.app.post(func(a *App) { *f.texts["text"] = "echo \"$GREETING from $(pwd)\"\nuname -s\n" })
				shot("shell-text")

				// The interpreter list: automatic, the terminal's POSIX shells and Custom…, then
				// Custom… with its field.
				awaitStateWithin(t, h, 10*time.Second, "the terminal's shells", func() bool { return len(h.app.term.shells.list) == 3 })
				interpreter, _ := runConfigFieldLabel(h.app.language(), "interpreter")
				h.click(center(h.hitLabeled(interpreter)))
				shot("interpreter-list")
				h.click(center(h.popupHit(i18n.Shared(h.app.language(), "desktop.runConfig.interpreterCustom"))))
				h.app.post(func(a *App) {
					*f.texts["interpreter"] = "/opt/homebrew/bin/bash"
					a.runConfigFormEdited(p, f)
				})
				awaitStateWithin(t, h, 10*time.Second, "the custom interpreter", func() bool { return !f.refreshing })
				shot("interpreter-custom")
				h.app.post(func(a *App) {
					*f.texts["interpreter"] = ""
					a.runConfigFormEdited(p, f)
				})
				awaitStateWithin(t, h, 10*time.Second, "the automatic interpreter", func() bool { return !f.refreshing })

				apply(runConfigDialogRun)
				awaitProcessRun(t, h, p, "Greet", nil)
				shot("run-output")

				h.app.post(func(a *App) {
					a.openRunConfigDialog(p, p.runConfigs.selected)
					d.newMenu = runConfigNewMenuToolbar
				})
				shot("new-menu")
				h.app.post(func(*App) { d.newMenu = runConfigNewMenuClosed })

				edit(runProviderPowerShell, map[string]string{"name": "Clean", "source": "file", "script": "scripts/clean.ps1"}, nil)
				shot("powershell")

				edit(runProviderExecutable, map[string]string{"name": "Tool", "program": "bin/tool", "programArguments": "--verbose \"two words\"", "workingDirectory": "bin"}, nil)
				shot("executable")

				edit(runProviderBatch, map[string]string{"name": "Package", "source": "text"}, nil)
				h.app.post(func(a *App) { *d.drafts[d.selected].form.texts["text"] = "@echo off\r\ncall build.cmd\r\n" })
				shot("batch")

				apply(runConfigDialogOK)
				awaitStateWithin(t, h, 10*time.Second, "the saved configurations", func() bool {
					c := p.titleConfiguration()
					return !p.runConfigs.loading && len(p.runConfigs.list) == 4 && c != nil && c.Name == "Package"
				})
				shot("title-unavailable")

				// The toolbar's folder, copy and sort: Greet in a folder of its own, the list in the
				// order it was made, the folder's pane, and a copy of Tool.
				id := func(name string) string {
					t.Helper()
					for _, configuration := range p.runConfigs.list {
						if configuration.Name == name {
							return configuration.ID
						}
					}
					t.Fatalf("no configuration %s in %v", name, listedNames(p))
					return ""
				}
				h.app.post(func(a *App) {
					a.openRunConfigDialog(p, id("Greet"))
					a.addRunConfigFolder(p)
				})
				h.settle()
				// The folder takes the name typed in its pane, as of the tree last painted.
				h.app.post(func(a *App) {
					d.folderName = "Scripts"
					a.renameRunConfigFolder(p)
					p.toggleRunConfigDialogSort()
					a.selectRunConfigDraft(p, id("Greet"))
				})
				shot("folders")
				h.app.post(func(*App) {
					d.selectRunConfigDialogNode(runConfigDialogNode{group: p.runConfigDialogGroupKey(id("Greet")), folder: "Scripts"})
				})
				shot("folder-pane")
				tool := id("Tool")
				h.app.post(func(a *App) { a.selectRunConfigDraft(p, tool) })
				awaitStateWithin(t, h, 10*time.Second, "Tool's editor", func() bool { return p.runConfigCopyable(tool) })
				h.app.post(func(a *App) { a.copyRunConfigDraft(p) })
				awaitStateWithin(t, h, 10*time.Second, "the copy's editor", func() bool {
					draft := d.drafts[d.selected]
					return d.selected != tool && draft != nil && draft.form != nil && draft.form.ready()
				})
				shot("copy")
				h.app.post(func(a *App) { a.closeRunConfigDialog(p) })

				plugins := filepath.Join(root, ".lithe", "run", "plugin")
				if err := os.MkdirAll(plugins, 0o755); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(filepath.Join(plugins, "dev.example.engine.toml"), []byte("["), 0o600); err != nil {
					t.Fatal(err)
				}
				generation := p.runConfigs.generation
				h.app.post(func(a *App) { a.refreshRunConfigurations(p) })
				awaitStateWithin(t, h, 10*time.Second, "the unread file", func() bool {
					s := &p.runConfigs
					return s.generation > generation && !s.loading && len(s.ignored) == 1
				})
				h.click(center(h.button(itemRunConfig)))
				if note := i18n.Shared(h.app.language(), "desktop.runConfig.windowsOnlyType"); !h.shows(note) {
					t.Fatalf("the run menu does not mark Package with %q", note)
				}
				shot("run-menu")
			})
		}
	}
}
