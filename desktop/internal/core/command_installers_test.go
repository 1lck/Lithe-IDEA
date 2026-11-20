package core

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/contractfixture"
)

type commandInstallerCase struct {
	Name string `json:"name"`
	// Plugin names the case's manifest in place of the fixture's.
	Plugin        string          `json:"plugin"`
	Operation     string          `json:"operation"`
	Payload       json.RawMessage `json:"payload"`
	ManifestEdits []struct {
		Path  string          `json:"path"`
		Value json.RawMessage `json:"value"`
	} `json:"manifestEdits"`
	Expected  json.RawMessage `json:"expected"`
	Platforms map[string]struct {
		Payload  json.RawMessage `json:"payload"`
		Expected json.RawMessage `json:"expected"`
	} `json:"platforms"`
}

// The wrappers answer every golden case of the shared fixture the way Core's own test reads
// it: a result matches field for field, a rejection by its code and field.
func TestCommandInstallersSharedFixture(t *testing.T) {
	directory := contractfixture.Path("fixtures/command-installers")
	data, err := os.ReadFile(filepath.Join(directory, "command-installer-plans.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Plugin string                 `json:"plugin"`
		Cases  []commandInstallerCase `json:"cases"`
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	plugins := map[string][]byte{}
	load := func(name string) []byte {
		t.Helper()
		if plugin, ok := plugins[name]; ok {
			return plugin
		}
		plugin, err := os.ReadFile(filepath.Join(directory, name))
		if err != nil {
			t.Fatal(err)
		}
		plugins[name] = plugin
		return plugin
	}
	if len(fixture.Cases) == 0 {
		t.Fatal("fixture has no cases")
	}
	platform := "unix"
	if runtime.GOOS == "windows" {
		platform = "windows"
	}
	client := NewClient()
	for _, c := range fixture.Cases {
		t.Run(c.Name, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			payload, expected := c.Payload, c.Expected
			if specific, ok := c.Platforms[platform]; ok {
				payload = mergeObjects(t, payload, specific.Payload)
				expected = specific.Expected
			}
			pluginName := fixture.Plugin
			if c.Plugin != "" {
				pluginName = c.Plugin
			}
			manifest := editManifest(t, load(pluginName), c)
			var fields struct {
				InstallerID      string                  `json:"installerID"`
				Target           string                  `json:"target"`
				InstallDirectory string                  `json:"installDirectory"`
				Platform         *CommandArchivePlatform `json:"platform"`
				Outputs          []*string               `json:"outputs"`
			}
			if err := json.Unmarshal(payload, &fields); err != nil {
				t.Fatal(err)
			}
			var got any
			switch c.Operation {
			case "requirements":
				got, err = client.CommandInstallerRequirements(ctx, manifest, fields.Platform)
			case "plan":
				got, err = client.PlanCommandInstaller(ctx, manifest, fields.InstallerID, fields.Target, fields.InstallDirectory, fields.Platform)
			case "defaultDirectory":
				var directory string
				var ok bool
				directory, ok, err = client.CommandInstallerDefaultDirectory(ctx, manifest, fields.InstallerID, fields.Outputs)
				if ok {
					got = directory
				}
			default:
				t.Fatalf("unknown operation %q", c.Operation)
			}
			var want struct {
				Status       string          `json:"status"`
				Code         string          `json:"code"`
				Field        string          `json:"field"`
				Requirements json.RawMessage `json:"requirements"`
				Plan         json.RawMessage `json:"plan"`
				Directory    json.RawMessage `json:"directory"`
			}
			if err := json.Unmarshal(expected, &want); err != nil {
				t.Fatal(err)
			}
			if want.Status == "rejected" {
				var rejection *MarketplaceRejection
				if !errors.As(err, &rejection) || rejection.Code != want.Code || rejection.Field != want.Field {
					t.Fatalf("err = %v, want %s (%s)", err, want.Code, want.Field)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			wantValue := want.Requirements
			switch c.Operation {
			case "plan":
				wantValue = want.Plan
			case "defaultDirectory":
				wantValue = want.Directory
			}
			sameJSON(t, got, wantValue)
		})
	}
}

// A plan whose target does not match the directory it carries is not one the host can run.
func TestPlanCommandInstallerRefusesAnInconsistentOutcome(t *testing.T) {
	directory := contractfixture.Path("fixtures/command-installers")
	manifest, err := os.ReadFile(filepath.Join(directory, "command-installer.plugin.json"))
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	client := NewClient()
	if _, err := client.PlanCommandInstaller(ctx, manifest, "sample-ls", "unknown", "", nil); err == nil {
		t.Fatal("an unknown target was planned")
	}
	if directory, ok, err := client.CommandInstallerDefaultDirectory(ctx, manifest, "sample-ls", []*string{nil, nil}); err != nil || ok || directory != "" {
		t.Fatalf("failed probes gave %q, %v, %v", directory, ok, err)
	}
}

// A download plan is one the host can carry out only when it installs into the managed target
// with nothing to run and names an archive it can check.
func TestCommandInstallPlanConsistency(t *testing.T) {
	tool := "builder"
	directory := "/data/commands/sample"
	download := func(edit func(*CommandInstallDownload)) *CommandInstallDownload {
		d := &CommandInstallDownload{Installer: "sample", URL: "https://example.org/a.zip", SHA256: strings.Repeat("a", 64), Archive: "zip", CacheKey: strings.Repeat("b", 64)}
		if edit != nil {
			edit(d)
		}
		return d
	}
	for _, c := range []struct {
		name string
		plan CommandInstallPlan
		want bool
	}{
		{"managed tool plan", CommandInstallPlan{Installer: "sample", Target: CommandInstallManaged, Tool: &tool, CommandDirectory: &directory}, true},
		{"toolDefault tool plan", CommandInstallPlan{Installer: "sample", Target: CommandInstallToolDefault, Tool: &tool}, true},
		{"managed tool plan without a directory", CommandInstallPlan{Installer: "sample", Target: CommandInstallManaged, Tool: &tool}, false},
		{"tool plan without a tool", CommandInstallPlan{Installer: "sample", Target: CommandInstallManaged, CommandDirectory: &directory}, false},
		{"download plan", CommandInstallPlan{Installer: "sample", Target: CommandInstallManaged, Download: download(nil)}, true},
		{"download plan for toolDefault", CommandInstallPlan{Installer: "sample", Target: CommandInstallToolDefault, Download: download(nil)}, false},
		{"download plan with a tool", CommandInstallPlan{Installer: "sample", Target: CommandInstallManaged, Tool: &tool, Download: download(nil)}, false},
		{"download plan with a command directory", CommandInstallPlan{Installer: "sample", Target: CommandInstallManaged, CommandDirectory: &directory, Download: download(nil)}, false},
		{"download plan with arguments", CommandInstallPlan{Installer: "sample", Target: CommandInstallManaged, Arguments: []string{"x"}, Download: download(nil)}, false},
		{"download of another installer", CommandInstallPlan{Installer: "sample", Target: CommandInstallManaged, Download: download(func(d *CommandInstallDownload) { d.Installer = "other" })}, false},
		{"download without a digest", CommandInstallPlan{Installer: "sample", Target: CommandInstallManaged, Download: download(func(d *CommandInstallDownload) { d.SHA256 = "" })}, false},
		{"download of an unknown format", CommandInstallPlan{Installer: "sample", Target: CommandInstallManaged, Download: download(func(d *CommandInstallDownload) { d.Archive = "rar" })}, false},
	} {
		if got := c.plan.consistent(); got != c.want {
			t.Errorf("%s: consistent() = %v, want %v", c.name, got, c.want)
		}
	}
}

func mergeObjects(t *testing.T, base, overlay json.RawMessage) json.RawMessage {
	t.Helper()
	merged := map[string]json.RawMessage{}
	for _, part := range []json.RawMessage{base, overlay} {
		if len(part) == 0 {
			continue
		}
		var object map[string]json.RawMessage
		if err := json.Unmarshal(part, &object); err != nil {
			t.Fatal(err)
		}
		for key, value := range object {
			merged[key] = value
		}
	}
	out, err := json.Marshal(merged)
	if err != nil {
		t.Fatal(err)
	}
	return out
}

// editManifest replaces the value at each of the case's JSON pointers.
func editManifest(t *testing.T, plugin []byte, c commandInstallerCase) json.RawMessage {
	t.Helper()
	if len(c.ManifestEdits) == 0 {
		return plugin
	}
	var document any
	if err := json.Unmarshal(plugin, &document); err != nil {
		t.Fatal(err)
	}
	for _, edit := range c.ManifestEdits {
		var value any
		if err := json.Unmarshal(edit.Value, &value); err != nil {
			t.Fatal(err)
		}
		segments := strings.Split(strings.TrimPrefix(edit.Path, "/"), "/")
		parent := document
		for _, segment := range segments[:len(segments)-1] {
			parent = child(t, parent, segment)
		}
		last := segments[len(segments)-1]
		switch node := parent.(type) {
		case map[string]any:
			node[last] = value
		case []any:
			index, err := strconv.Atoi(last)
			if err != nil || index < 0 || index >= len(node) {
				t.Fatalf("bad pointer %s", edit.Path)
			}
			node[index] = value
		default:
			t.Fatalf("bad pointer %s", edit.Path)
		}
	}
	out, err := json.Marshal(document)
	if err != nil {
		t.Fatal(err)
	}
	return out
}

func child(t *testing.T, node any, segment string) any {
	t.Helper()
	switch value := node.(type) {
	case map[string]any:
		return value[segment]
	case []any:
		index, err := strconv.Atoi(segment)
		if err != nil || index < 0 || index >= len(value) {
			t.Fatalf("bad pointer segment %s", segment)
		}
		return value[index]
	}
	t.Fatalf("bad pointer segment %s", segment)
	return nil
}

func sameJSON(t *testing.T, got any, want json.RawMessage) {
	t.Helper()
	encoded, err := json.Marshal(got)
	if err != nil {
		t.Fatal(err)
	}
	var gotValue, wantValue any
	if err := json.Unmarshal(encoded, &gotValue); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(want, &wantValue); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(gotValue, wantValue) {
		t.Fatalf("got %s\nwant %s", encoded, want)
	}
}
