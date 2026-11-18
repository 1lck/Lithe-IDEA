//go:build vivahead && lithevisual

package workbench

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/headless"
)

// TestVisualBuiltInProcessRuns captures the built-in runs of a project without any plugin:
// the editor of a shell script with a script file and with script text, the Run window after
// the script ran, the menu that creates a run of each kind this platform offers, the editors
// of a PowerShell script and of an executable, and the title bar's run menu naming a run
// configuration file that was not read. The script runs under the system's shell. It needs
// only LITHE_VISUAL_OUTPUT_DIR; the dark captures are in Chinese and the light ones in English.
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
				p := h.openTree(t, root)
				h.app.post(func(a *App) { a.refreshRunConfigurations(p) })
				awaitStateWithin(t, h, 10*time.Second, "the run kinds", func() bool {
					s := &p.runConfigs
					return s.generation > 0 && !s.loading && s.types != nil
				})
				f := &p.runConfigs.form
				// edit opens the editor of a new run of provider, sets the texts and checkboxes
				// given, and waits for the fields that follow the edit.
				edit := func(provider string, texts map[string]string, flags map[string]bool, variables ...*runConfigVariable) {
					t.Helper()
					// The editor closed before keeps its fields, so the one waited for is told
					// apart by its generation.
					var generation uint64
					h.app.post(func(a *App) {
						a.openRunConfigForm(p, provider, "")
						generation = f.generation
					})
					awaitStateWithin(t, h, 10*time.Second, "the editor of "+provider, func() bool {
						return generation != 0 && f.generation == generation && f.open && !f.loading && f.fields != nil
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
						a.runConfigFormEdited(p)
					})
					awaitStateWithin(t, h, 10*time.Second, "the edited editor", func() bool { return !f.refreshing })
				}

				edit(runProviderShell, map[string]string{"name": "Greet", "source": "file", "script": "scripts/greet.sh", "scriptOptions": "Lithe", "workingDirectory": "scripts"},
					map[string]bool{"storeAsProjectFile": true}, &runConfigVariable{name: "GREETING", value: "Hello"})
				shot("shell-file")

				h.app.post(func(a *App) {
					*f.texts["source"] = "text"
					a.runConfigFormEdited(p)
				})
				awaitStateWithin(t, h, 10*time.Second, "the script text field", func() bool { return !f.refreshing && f.texts["text"] != nil })
				h.app.post(func(a *App) { *f.texts["text"] = "echo \"$GREETING from $(pwd)\"\nuname -s\n" })
				shot("shell-text")

				h.app.post(func(a *App) { a.saveRunConfigForm(p, runConfigFormRun) })
				awaitStateWithin(t, h, 10*time.Second, "the save", func() bool { return !f.open || len(f.errors) > 0 || f.failure != "" })
				if f.open {
					t.Fatalf("the editor stayed open: errors %v failure %q", f.errors, f.failure)
				}
				awaitProcessRun(t, h, p, "Greet", nil)
				shot("run-output")

				h.click(center(h.button(itemBuild)))
				h.settleChain()
				h.app.post(func(a *App) { p.runConfigs.newMenu = true })
				shot("new-menu")
				h.app.post(func(a *App) { p.runConfigs.newMenu = false })

				edit(runProviderPowerShell, map[string]string{"name": "Clean", "source": "file", "script": "scripts/clean.ps1"}, nil)
				shot("powershell")
				h.app.post(func(a *App) { a.closeRunConfigForm(p) })

				edit(runProviderExecutable, map[string]string{"name": "Tool", "program": "bin/tool", "programArguments": "--verbose \"two words\"", "workingDirectory": "bin"}, nil)
				shot("executable")
				h.app.post(func(a *App) { a.closeRunConfigForm(p) })

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
				shot("run-menu")
			})
		}
	}
}
