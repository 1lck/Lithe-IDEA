package pluginsettings

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/configfile"
	"github.com/1lck/Lithe-IDEA/desktop/internal/contractfixture"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// translatedFixture is the contract's settings manifest and the directory holding its packaged
// l10n/zh-Hans.json, which the tests read in place as an installed package.
func translatedFixture(t *testing.T) (json.RawMessage, string) {
	t.Helper()
	directory := contractfixture.Path("fixtures/settings")
	manifest, err := os.ReadFile(filepath.Join(directory, "settings.plugin.json"))
	if err != nil {
		t.Fatal(err)
	}
	return manifest, directory
}

func declaration(t *testing.T, state core.PluginSettingsState, id string) core.PluginSettingDeclaration {
	t.Helper()
	for _, row := range state.Rows {
		if row.Declaration.ID == id {
			return row.Declaration
		}
	}
	t.Fatalf("no row %q in %+v", id, state.Rows)
	return core.PluginSettingDeclaration{}
}

// assertTranslated checks the text l10n/zh-Hans.json gives the fixture manifest.
func assertTranslated(t *testing.T, state core.PluginSettingsState) {
	t.Helper()
	localization := state.Localization
	if localization == nil || localization.Applied == nil || *localization.Applied != "l10n/zh-Hans.json" || len(localization.Rejected) != 0 {
		t.Fatalf("translation not applied: %+v", localization)
	}
	if title := declaration(t, state, "dialyzer").Title; title != "Dialyzer 静态分析" {
		t.Fatalf("dialyzer title %q", title)
	}
	checks := declaration(t, state, "checks")
	if checks.Title != "检查项" || len(checks.Options) != 2 || checks.Options[0].Title != "格式检查" || checks.Options[1].Title != "Credo" {
		t.Fatalf("checks not translated, untranslated option not kept: %+v", checks)
	}
	// A row's section stays the manifest heading, a grouping key; the view shows the section title.
	var titles []string
	for _, section := range state.Sections {
		titles = append(titles, section.Title)
	}
	if len(titles) != 2 || titles[0] != "" || titles[1] != "服务器" {
		t.Fatalf("section titles %q", titles)
	}
	if len(state.Actions) != 1 || state.Actions[0].Title != "重建 PLT" {
		t.Fatalf("action not translated: %+v", state.Actions)
	}
}

func TestPresentedLoadAppliesPackageTranslationAndReadbackKeepsIt(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	manifest, directory := translatedFixture(t)
	store, workspace := New(core.NewClient(), filepath.Join(t.TempDir(), "preferences")), t.TempDir()

	plain, err := store.Load(ctx, manifest, workspace)
	if err != nil {
		t.Fatal(err)
	}
	if plain.State.Localization != nil || declaration(t, plain.State, "dialyzer").Title != "Dialyzer" {
		t.Fatalf("a load without a language changed manifest text: %+v", plain.State.Localization)
	}

	snapshot, err := store.LoadPresented(ctx, manifest, workspace, Presentation{Language: "zh-Hans", Package: directory})
	if err != nil {
		t.Fatal(err)
	}
	assertTranslated(t, snapshot.State)
	// l10n/zh.json, the shorter candidate, is absent: expected, not a read failure.
	if got := snapshot.State.Localization.Candidates; len(got) != 2 || got[0] != "l10n/zh-Hans.json" || got[1] != "l10n/zh.json" {
		t.Fatalf("candidates %v", got)
	}
	if failures := snapshot.LocalizationReadFailures(); len(failures) != 0 {
		t.Fatalf("absent candidate reported: %+v", failures)
	}

	saved, err := store.Save(ctx, snapshot, "project", []core.PluginSettingEdit{{ID: "dialyzer", Value: json.RawMessage(`false`)}}, nil)
	if err != nil || !saved.Committed || saved.Readback == nil {
		t.Fatalf("save: %+v, %v", saved, err)
	}
	assertTranslated(t, saved.Readback.State)
	for _, row := range saved.Readback.State.Rows {
		if row.Declaration.ID == "dialyzer" && string(row.Effective.Value) != "false" {
			t.Fatalf("readback lost the saved value: %+v", row)
		}
	}
}

// TestPresentedLoadFollowsContractLocalizationCases runs every case of the contract through the
// adapter: the files are placed in a package, read from the candidates Core names, and Core's
// report must match the case.
func TestPresentedLoadFollowsContractLocalizationCases(t *testing.T) {
	data, err := os.ReadFile(contractfixture.Path("fixtures/settings/localization-cases.json"))
	if err != nil {
		t.Fatal(err)
	}
	var suite struct {
		Manifest string `json:"manifest"`
		Cases    []struct {
			Name     string                     `json:"name"`
			Language string                     `json:"language"`
			Files    map[string]json.RawMessage `json:"files"`
			Applied  *string                    `json:"applied"`
			Rejected []struct {
				Path  string  `json:"path"`
				Field *string `json:"field"`
			} `json:"rejected"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(data, &suite); err != nil {
		t.Fatal(err)
	}
	if len(suite.Cases) == 0 {
		t.Fatal("no localization cases")
	}
	manifest, err := os.ReadFile(contractfixture.Path("fixtures/settings/" + suite.Manifest))
	if err != nil {
		t.Fatal(err)
	}
	for _, c := range suite.Cases {
		t.Run(c.Name, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			directory := t.TempDir()
			for path, value := range c.Files {
				// A JSON string is text sent as is; any other value is sent serialized.
				text := []byte(value)
				var literal string
				if json.Unmarshal(value, &literal) == nil {
					text = []byte(literal)
				}
				target := filepath.Join(directory, filepath.FromSlash(path))
				if err := os.MkdirAll(filepath.Dir(target), 0o700); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(target, text, 0o600); err != nil {
					t.Fatal(err)
				}
			}
			snapshot, err := New(core.NewClient(), t.TempDir()).LoadPresented(ctx, manifest, "", Presentation{Language: c.Language, Package: directory})
			if err != nil {
				t.Fatal(err)
			}
			localization := snapshot.State.Localization
			if localization == nil || localization.ReadRequired {
				t.Fatalf("no final report: %+v", localization)
			}
			if (localization.Applied == nil) != (c.Applied == nil) || (c.Applied != nil && *localization.Applied != *c.Applied) {
				t.Fatalf("applied %v, want %v", localization.Applied, c.Applied)
			}
			if len(localization.Rejected) != len(c.Rejected) {
				t.Fatalf("rejected %+v, want %+v", localization.Rejected, c.Rejected)
			}
			for index, want := range c.Rejected {
				got := localization.Rejected[index]
				field := ""
				if want.Field != nil {
					field = *want.Field
				}
				if got.Path != want.Path || got.Error.Field != field || got.Error.Code != "plugin.settings.invalidLocalization" {
					t.Fatalf("rejection %d: %+v, want %s %q", index, got, want.Path, field)
				}
			}
			if failures := snapshot.LocalizationReadFailures(); len(failures) != 0 {
				t.Fatalf("readable files reported unreadable: %+v", failures)
			}
		})
	}
}

func TestUnreadableTranslationIsSkippedAndReported(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	manifest, _ := translatedFixture(t)
	directory := t.TempDir()
	// The specific candidate is a directory, so it cannot be read; the shorter one still serves.
	if err := os.MkdirAll(filepath.Join(directory, "l10n", "zh-Hans.json"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(directory, "l10n", "zh.json"), []byte(`{"settings":{"dialyzer":{"title":"中文"}}}`), 0o600); err != nil {
		t.Fatal(err)
	}
	before, err := os.ReadDir(filepath.Join(directory, "l10n"))
	if err != nil {
		t.Fatal(err)
	}
	snapshot, err := New(core.NewClient(), t.TempDir()).LoadPresented(ctx, manifest, "", Presentation{Language: "zh-Hans", Package: directory})
	if err != nil {
		t.Fatal(err)
	}
	failures := snapshot.LocalizationReadFailures()
	if len(failures) != 1 || failures[0].Path != "l10n/zh-Hans.json" || !errors.Is(failures[0].Err, configfile.ErrTarget) {
		t.Fatalf("read failures %+v", failures)
	}
	if applied := snapshot.State.Localization.Applied; applied == nil || *applied != "l10n/zh.json" {
		t.Fatalf("applied %v", applied)
	}
	if title := declaration(t, snapshot.State, "dialyzer").Title; title != "中文" {
		t.Fatalf("dialyzer title %q", title)
	}
	after, err := os.ReadDir(filepath.Join(directory, "l10n"))
	if err != nil || len(after) != len(before) {
		t.Fatalf("reading translations changed the package: %v, %v", after, err)
	}
}
