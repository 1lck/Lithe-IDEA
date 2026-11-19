package workbench

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
)

// treeOptionsRuntimeManifest runs the fixture's build tool, a wrapper in the project, on a runtime the
// toolchain resolver selects.
var treeOptionsRuntimeManifest = strings.Replace(treeOptionsStaticManifest,
	`"executables": [{"kind": "command", "command": "fixture-build"}],`,
	`"executables": [{"kind": "projectFile", "path": "fixturew"}],
      "runtimeDependencies": [{"id": "fixture-runtime", "executables": [{"kind": "toolchain", "toolchainID": "fixture-runtime"}]}],`, 1)

// A build system's options dialog shows the build tool and the runtime it runs on, where each came from,
// and a way to the Toolchains page, where the project's one runtime is chosen. An option saved before the
// plugin stopped declaring it is listed with its value, and Clear removes this machine's value.
func TestBuildOptionsShowTheRuntimeAndDroppedOptions(t *testing.T) {
	h, p := openTreeOptionsProjectWith(t, &testKernel{Client: core.NewClient()}, treeOptionsRuntimeManifest)
	language := h.app.language()
	wrapper := filepath.Join(p.root, "fixturew")
	if err := os.WriteFile(wrapper, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	const runtimeExecutable = "/opt/fixture-runtime/bin/run"
	h.app.toolchainResolve = func(_ context.Context, _, _, tool, _ string) (core.ToolchainSelection, error) {
		if tool != "fixture-runtime" {
			t.Errorf("resolved toolchain %q, want fixture-runtime", tool)
		}
		return core.ToolchainSelection{Executable: runtimeExecutable, Version: "21.0.2", Layer: "project"}, nil
	}

	// The plugin no longer declares legacyHome; its value is still saved on this machine.
	local := json.RawMessage(`{"version":1,"document":{"version":1,"systems":{"fixture-profiles":{"options":{"legacyHome":"/opt/fixture-17"}}}}}`)
	if err := h.app.storeBuildLocalOptions(p.root, local); err != nil {
		t.Fatal(err)
	}
	h.app.requestBuildReload(p)
	awaitStateWithin(t, h, 10*time.Second, "detection to report the dropped option", func() bool {
		instance := p.selectedBuildInstance()
		return !p.build.loading && instance != nil && slices.Contains(instance.DroppedOptions, "legacyHome")
	})
	h.settle()

	h.clickNamed(h.instanceOptions(p))
	awaitStateWithin(t, h, 10*time.Second, "the runtime section and the dropped option", func() bool {
		e := &p.build.options
		return e.open && !e.loading && e.runtimesLoaded && len(e.dropped) == 1
	})
	h.settle()
	runtimes := p.build.options.runtimes
	if len(runtimes) != 2 {
		t.Fatalf("runtime rows = %+v, want the tool and its runtime", runtimes)
	}
	if tool := runtimes[0]; tool.name != "Fixture Build" || tool.executable != wrapper || tool.source.Kind != "projectFile" {
		t.Fatalf("tool row = %+v, want the project's wrapper", tool)
	}
	if run := runtimes[1]; run.name != "fixture-runtime" || run.executable != runtimeExecutable || run.source.Kind != "toolchain" {
		t.Fatalf("runtime row = %+v, want the toolchain's selection", run)
	}
	for _, label := range []string{
		i18n.Shared(language, "desktop.build.runtimeHeading"),
		runtimeExecutable,
		buildExecutionSourceLabel(language, runtimes[1].source),
		i18n.Shared(language, "desktop.build.sourceProjectFile"),
		// The notice wraps; its first words are on its first line.
		strings.Join(strings.Fields(i18n.Shared(language, "desktop.build.droppedOptions"))[:4], " "),
		"legacyHome = /opt/fixture-17",
	} {
		if !h.shows(label) {
			t.Fatalf("the dialog does not show %q", label)
		}
	}
	if !strings.Contains(buildExecutionSourceLabel(language, runtimes[1].source), "21.0.2") {
		t.Fatalf("the runtime's source %q does not name its version", buildExecutionSourceLabel(language, runtimes[1].source))
	}
	if h.hitLabeled(i18n.Shared(language, "desktop.build.openToolchains")).Width == 0 {
		t.Fatal("the dialog has no way to the Toolchains page")
	}

	h.clickShared("desktop.build.clearDropped")
	awaitStateWithin(t, h, 10*time.Second, "the dropped value to be removed", func() bool {
		e := &p.build.options
		return e.open && !e.saving && len(e.dropped) == 0
	})
	docs, err := h.app.readBuildOptionDocuments(context.Background(), p.root)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(docs.local), "legacyHome") {
		t.Fatalf("local options %s still hold the dropped option", docs.local)
	}
	awaitStateWithin(t, h, 10*time.Second, "detection without the dropped option", func() bool {
		instance := p.selectedBuildInstance()
		return !p.build.loading && instance != nil && len(instance.DroppedOptions) == 0
	})
	h.settle()

	// The Toolchains page opens in a window of its own, which a window made without an application cannot
	// open; the button reports nothing and keeps the dialog.
	h.clickShared("desktop.build.openToolchains")
	h.settle()
	if h.app.notice != "" || !p.build.options.open {
		t.Fatalf("after Toolchain Settings… notice = %q, dialog open %v", h.app.notice, p.build.options.open)
	}
}

// A runtime's source names the toolchain's version and the layer it was selected from, or the variable,
// PATH, setting or wrapper it was found by.
func TestBuildExecutionSourceLabel(t *testing.T) {
	language := i18n.English
	for _, test := range []struct {
		source buildExecutionSource
		want   string
	}{
		{buildExecutionSource{Kind: "toolchain", Version: "17.0.9"}, "17.0.9"},
		{buildExecutionSource{Kind: "environment", Variable: "FIXTURE_HOME"}, i18n.SharedFormat(language, "desktop.build.sourceEnvironment", map[string]string{"variable": "FIXTURE_HOME"})},
		{buildExecutionSource{Kind: "command"}, i18n.Shared(language, "desktop.build.sourcePath")},
		{buildExecutionSource{Kind: "setting"}, i18n.Shared(language, "desktop.build.sourceSetting")},
		{buildExecutionSource{}, ""},
	} {
		if got := buildExecutionSourceLabel(language, test.source); got != test.want {
			t.Errorf("source %+v = %q, want %q", test.source, got, test.want)
		}
	}
}
