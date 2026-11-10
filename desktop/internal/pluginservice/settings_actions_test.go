package pluginservice

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/configfile"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginstate"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

type settingsActionKernel struct {
	*settingsPlanningKernel
	afterPlan func()
}

func (k *settingsActionKernel) PlanPluginSettingsAction(ctx context.Context, request core.PluginSettingsActionRequest) (core.PluginSettingsActionPlan, error) {
	plan, err := k.client.PlanPluginSettingsAction(ctx, request)
	if k.afterPlan != nil {
		k.afterPlan()
	}
	return plan, err
}

func TestSettingsActionPlanningRechecksNativeOwnersWithoutPublishing(t *testing.T) {
	for _, scenario := range []string{"confirmation", "confirmed", "disabled", "disabled-during-plan", "manifest", "uninstall", "directory", "workspace", "workspace-during-plan", "closed-window"} {
		t.Run(scenario, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			manifest, err := os.ReadFile("../../../shared/contracts/plugins/v1/fixtures/settings/settings-v2.plugin.json")
			if err != nil {
				t.Fatal(err)
			}
			preferences, plugins, workspace := t.TempDir(), t.TempDir(), filepath.Join(t.TempDir(), "project")
			if err := os.Mkdir(workspace, 0o700); err != nil {
				t.Fatal(err)
			}
			packageRoot := filepath.Join(plugins, "dev.lithe.fixture.settings-v2", "0.1.0")
			writePackage := func() {
				t.Helper()
				if err := os.MkdirAll(packageRoot, 0o700); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(filepath.Join(packageRoot, "plugin.json"), manifest, 0o600); err != nil {
					t.Fatal(err)
				}
			}
			writePackage()
			storage := store.At(preferences)
			state := pluginstate.New(storage)
			if err := state.SetEnabled("dev.lithe.fixture.settings-v2", true); err != nil {
				t.Fatal(err)
			}
			kernel := &settingsActionKernel{settingsPlanningKernel: &settingsPlanningKernel{fakeKernel: &fakeKernel{}, client: core.NewClient()}}
			service, err := Open(kernel, storage, plugins)
			if err != nil {
				t.Fatal(err)
			}
			editor, err := service.LoadSettingsEditor(ctx, "dev.lithe.fixture.settings-v2", workspace)
			if err != nil {
				t.Fatal(err)
			}
			replaceWorkspace := func() {
				t.Helper()
				if err := os.Rename(workspace, workspace+"-old"); err != nil {
					t.Fatal(err)
				}
				if err := os.Mkdir(workspace, 0o700); err != nil {
					t.Fatal(err)
				}
			}
			var check func() error
			switch scenario {
			case "disabled":
				if err := state.SetEnabled("dev.lithe.fixture.settings-v2", false); err != nil {
					t.Fatal(err)
				}
			case "disabled-during-plan":
				kernel.afterPlan = func() {
					if err := state.SetEnabled("dev.lithe.fixture.settings-v2", false); err != nil {
						t.Fatal(err)
					}
				}
			case "manifest":
				if err := os.WriteFile(filepath.Join(packageRoot, "plugin.json"), append(manifest, '\n'), 0o600); err != nil {
					t.Fatal(err)
				}
			case "uninstall":
				if err := os.RemoveAll(packageRoot); err != nil {
					t.Fatal(err)
				}
			case "directory":
				if err := os.Rename(packageRoot, filepath.Join(t.TempDir(), "retired")); err != nil {
					t.Fatal(err)
				}
				writePackage()
			case "workspace":
				replaceWorkspace()
			case "workspace-during-plan":
				kernel.afterPlan = replaceWorkspace
			case "closed-window":
				check = func() error { return configfile.ErrConflict }
			}
			plan, err := service.PlanSettingsEditorAction(ctx, editor, "rebuildPlt", scenario == "confirmed", check)
			switch scenario {
			case "confirmation":
				if err != nil || plan.Kind != "confirmationRequired" || plan.Function != "" {
					t.Fatalf("confirmation plan: %+v %v", plan, err)
				}
			case "confirmed":
				if err != nil || plan.Kind != "invoke" || plan.Function != "dialyzer.rebuild" || string(plan.Params) != "{}" {
					t.Fatalf("invocation plan: %+v %v", plan, err)
				}
			case "disabled":
				if err != nil || plan.Kind != "unavailable" || plan.Reason != "pluginDisabled" || plan.Function != "" {
					t.Fatalf("disabled plan: %+v %v", plan, err)
				}
			default:
				if !errors.Is(err, configfile.ErrConflict) {
					t.Fatalf("changed %s accepted: %+v %v", scenario, plan, err)
				}
			}
			for _, path := range []string{filepath.Join(preferences, "plugin-settings.json"), filepath.Join(workspace, ".lithe")} {
				if _, err := os.Stat(path); !errors.Is(err, os.ErrNotExist) {
					t.Fatalf("planning published preferences: %s %v", path, err)
				}
			}
		})
	}
}
