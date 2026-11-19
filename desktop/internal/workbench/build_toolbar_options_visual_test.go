//go:build vivahead

package workbench

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginicons"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/headless"
)

// TestVisualBuildToolbarToggleAndOptionPaths captures the Build window with a toolbar toggle on
// and the build system's own options dialog, whose directory option has a browse button and whose
// settings file shows the tool's value until Override is checked, with an ⓘ (#2202, #2152).
func TestVisualBuildToolbarToggleAndOptionPaths(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0o755); err != nil {
		t.Fatal(err)
	}
	manifest := strings.NewReplacer(
		`"options": [{"id": "offline"`,
		`"options": [{"id": "home", "displayName": "Home", "kind": "directory", "environment": {"FIXTURE_HOME": "${value}"}},
		{"id": "settingsFile", "displayName": "User settings file", "kind": "file",
		 "description": "The settings file passed to the tool.", "arguments": ["-s", "${value}"]}, {"id": "offline"`,
		`"optionDefaults": {"profiles": {"each": "/defaultProfiles/*", "value": "@key"}}`,
		`"optionDefaults": {"profiles": {"each": "/defaultProfiles/*", "value": "@key"},
          "settingsFile": {"each": "/package", "value": "/settings"}}`,
	).Replace(treeOptionsToolbarManifest)
	for _, scene := range []struct{ theme, language string }{{"light", "zh-CN"}, {"dark", "en-US"}} {
		name := scene.theme + "-" + scene.language
		t.Run(name, func(t *testing.T) {
			preferences, pluginRoot, root := treeOptionsWorkspace(t, manifest, scene.theme)
			var session *headless.Session
			h := newHarnessWithDriver(t, Options{
				Kernel: &testKernel{Client: core.NewClient()}, PluginKernel: &testKernel{Client: core.NewClient()},
				PluginRoot: pluginRoot, Store: preferences, Languages: []string{scene.language},
			}, func(config app.Config) (*app.Driver, func(), error) {
				config.Width, config.Height = 1280, 800
				var err error
				session, err = headless.Open(config, nil, headless.Options{Scale: 1})
				if err != nil {
					return nil, nil, err
				}
				return session.Driver(), session.Close, nil
			})
			p := showTreeOptionsProject(t, h, root)
			instance := p.selectedBuildInstance()
			awaitStateWithin(t, h, 10*time.Second, "the toggle's icon", func() bool {
				_, ok := h.app.pluginIcons.Lookup(instance.PluginID, pluginicons.Declaration{Path: "icons/offline.svg"})
				return ok
			})
			h.app.post(func(a *App) { a.toggleBuildToolbarOption(p, instance.ID, "offline") })
			awaitStateWithin(t, h, 10*time.Second, "the toggle to be on", func() bool {
				instance := p.selectedBuildInstance()
				return !p.build.optionSaving && !p.build.loading && instance != nil && instance.optionOn("offline")
			})
			h.settle()
			if err := session.Screenshot(filepath.Join(out, "build-toolbar-toggle-"+name+".png")); err != nil {
				t.Fatal(err)
			}
			h.clickNamed(h.instanceOptions(p))
			h.settleUntil("the options dialog", func() bool {
				e := &p.build.options
				return e.open && !e.loading && len(e.fields) == 4 && e.fields[1].implicit != ""
			})
			h.settle()
			if err := session.Screenshot(filepath.Join(out, "build-instance-options-"+name+".png")); err != nil {
				t.Fatal(err)
			}
			h.clickShared("desktop.build.optionOverride")
			h.settle()
			if err := session.Screenshot(filepath.Join(out, "build-instance-options-override-"+name+".png")); err != nil {
				t.Fatal(err)
			}
		})
	}
}

// TestVisualBuildOptionsRuntimeAndDroppedOptions captures a build system's options dialog with its
// Runtime section, the tool and the runtime it runs on with where each came from, and the notice of an
// option saved before the plugin stopped declaring it (#2203).
func TestVisualBuildOptionsRuntimeAndDroppedOptions(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, scene := range []struct{ theme, language string }{{"light", "zh-CN"}, {"dark", "en-US"}} {
		name := scene.theme + "-" + scene.language
		t.Run(name, func(t *testing.T) {
			preferences, pluginRoot, root := treeOptionsWorkspace(t, treeOptionsRuntimeManifest, scene.theme)
			if err := os.WriteFile(filepath.Join(root, "fixturew"), []byte("#!/bin/sh\n"), 0o755); err != nil {
				t.Fatal(err)
			}
			var session *headless.Session
			h := newHarnessWithDriver(t, Options{
				Kernel: &testKernel{Client: core.NewClient()}, PluginKernel: &testKernel{Client: core.NewClient()},
				PluginRoot: pluginRoot, Store: preferences, Languages: []string{scene.language},
			}, func(config app.Config) (*app.Driver, func(), error) {
				config.Width, config.Height = 1280, 800
				var err error
				session, err = headless.Open(config, nil, headless.Options{Scale: 1})
				if err != nil {
					return nil, nil, err
				}
				return session.Driver(), session.Close, nil
			})
			h.app.toolchainResolve = func(context.Context, string, string, string, string) (core.ToolchainSelection, error) {
				return core.ToolchainSelection{Executable: "/opt/fixture-runtime-21/bin/run", Version: "21.0.2", Layer: "project"}, nil
			}
			p := showTreeOptionsProject(t, h, root)
			local := json.RawMessage(`{"version":1,"document":{"version":1,"systems":{"fixture-profiles":{"options":{"legacyHome":"/opt/fixture-runtime-17"}}}}}`)
			if err := h.app.storeBuildLocalOptions(p.root, local); err != nil {
				t.Fatal(err)
			}
			h.app.requestBuildReload(p)
			awaitStateWithin(t, h, 10*time.Second, "the dropped option", func() bool {
				instance := p.selectedBuildInstance()
				return !p.build.loading && instance != nil && len(instance.DroppedOptions) == 1
			})
			h.settle()
			h.clickNamed(h.instanceOptions(p))
			h.settleUntil("the options dialog", func() bool {
				e := &p.build.options
				return e.open && !e.loading && e.runtimesLoaded && len(e.dropped) == 1
			})
			h.settle()
			if err := session.Screenshot(filepath.Join(out, "build-instance-runtime-"+name+".png")); err != nil {
				t.Fatal(err)
			}
		})
	}
}
