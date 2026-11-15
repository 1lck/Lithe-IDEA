package workbench

import (
	"encoding/json"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
)

// advancedGeneratorPlugin declares a generator whose advanced field starts
// valid, and one whose required advanced field starts empty.
func advancedGeneratorPlugin(t *testing.T) pluginservice.GeneratorPlugin {
	t.Helper()
	generator := func(id, name string, advanced map[string]any) map[string]any {
		return map[string]any{
			"id": id, "displayName": name, "section": "generator",
			"fields": []map[string]any{{"id": "label", "type": "text", "title": "Label", "default": "hello"}, advanced},
			"steps":  []map[string]any{{"kind": "command", "command": "scaffold-tool", "mayUseNetwork": false, "timeoutSeconds": 60}},
		}
	}
	manifest, err := json.Marshal(map[string]any{
		"schemaVersion": 0, "id": "dev.lithe.test.advanced", "displayName": "Advanced", "version": "1.0.0",
		"pluginAPIVersion": 0, "requires": map[string]int{"projectGenerators": 0},
		"vendor":      map[string]string{"id": "org.example", "displayName": "Example", "signatureRequirement": "publisherPackage"},
		"permissions": []string{"project.generate"}, "activationEvents": []string{},
		"projectGenerators": []map[string]any{
			generator("tuned", "Tuned", map[string]any{"id": "level", "type": "text", "title": "Level", "advanced": true, "default": "3"}),
			generator("strict", "Strict", map[string]any{"id": "module", "type": "text", "title": "Module", "advanced": true}),
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	return pluginservice.GeneratorPlugin{PluginID: "dev.lithe.test.advanced", Version: "1.0.0", Path: t.TempDir(), Enabled: true, Manifest: manifest}
}

// advancedChevronPointsDown reads the direction of the chevron the "Advanced
// Settings" button draws: a chevron pointing down is wider than it is tall, one
// pointing right is taller than it is wide.
func (h *harness) advancedChevronPointsDown() bool {
	h.t.Helper()
	button := h.pageHit("Advanced Settings").Bounds
	inside := func(p gfx.Point) bool {
		return p.X >= button.X && p.X <= button.X+button.Width && p.Y >= button.Y && p.Y <= button.Y+button.Height
	}
	left, top, right, bottom := button.X+button.Width, button.Y+button.Height, button.X, button.Y
	found := false
	for _, primitive := range h.driver.Snapshot().Primitives {
		if primitive.Kind != app.TrianglePrimitive || !inside(primitive.Points[0]) || !inside(primitive.Points[1]) || !inside(primitive.Points[2]) {
			continue
		}
		found = true
		for _, p := range primitive.Points {
			left, top, right, bottom = min(left, p.X), min(top, p.Y), max(right, p.X), max(bottom, p.Y)
		}
	}
	if !found {
		h.t.Fatalf("the Advanced Settings button %+v draws no chevron", button)
	}
	return right-left > bottom-top
}

// The chevron of "Advanced Settings" points down while the group is open and
// right while it is closed.
func TestNewProjectAdvancedSettingsChevronFollowsTheGroup(t *testing.T) {
	h := newGeneratorHarness(t, &testKernel{Client: core.NewClient()}, advancedGeneratorPlugin(t))
	h.openNewProjectSheet()
	h.chooseGenerator("Tuned", "dev.lithe.test.advanced/tuned")
	if h.shows("Level") || h.advancedChevronPointsDown() {
		t.Fatal("the advanced group of a valid form does not start closed with its chevron pointing right")
	}
	h.clickNamed("Advanced Settings")
	h.await("the advanced field", func() bool { return h.shows("Level") })
	if !h.advancedChevronPointsDown() {
		t.Fatal("the chevron of the open advanced group does not point down")
	}
	h.clickNamed("Advanced Settings")
	h.await("the advanced field to hide", func() bool { return !h.shows("Level") })
	if h.advancedChevronPointsDown() {
		t.Fatal("the chevron of the closed advanced group does not point right")
	}
}

// A problem in an advanced field disables Create, so the closed group opens to
// show it; the user can still close the group while the problem stays.
func TestNewProjectAdvancedSettingsOpenOnAProblem(t *testing.T) {
	h := newGeneratorHarness(t, &testKernel{Client: core.NewClient()}, advancedGeneratorPlugin(t))
	h.openNewProjectSheet()
	h.chooseGeneratorWithoutWaiting("Strict")
	required := i18n.Shared(h.app.language(), "desktop.newProject.problem.required")
	h.await("the empty required field to be explained", func() bool { return h.shows("Module") && h.shows(required) })
	if !h.advancedChevronPointsDown() || !h.pageHit("Create").Disabled {
		t.Fatal("the group opened for the problem does not point its chevron down, or Create is enabled")
	}
	h.clickNamed("Advanced Settings")
	h.await("the advanced group to close", func() bool { return !h.shows("Module") })
	h.app.invalidator.Invalidate()
	h.settle()
	if h.shows("Module") || h.advancedChevronPointsDown() {
		t.Fatal("the group reopened for a problem the user has already seen")
	}
}
