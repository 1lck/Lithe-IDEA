package workbench

import (
	"os"
	"path/filepath"
	"slices"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

func TestProjectMenuRemovesRecentRecordWithoutOpeningOrDeleting(t *testing.T) {
	for _, missing := range []bool{false, true} {
		t.Run(map[bool]string{false: "existing", true: "missing"}[missing], func(t *testing.T) {
			h := newHarness(t, &testKernel{Client: core.NewClient()})
			h.open(t.TempDir())
			p := h.app.project
			path := filepath.Join(t.TempDir(), "RecentProject")
			if !missing {
				if err := os.Mkdir(path, 0700); err != nil {
					t.Fatal(err)
				}
			}
			entries := append([]core.RecentProject{{Path: path, LastOpenedAt: 123}}, h.app.recent...)
			h.app.reduceRecent(entries, core.NormalizeRecent(), true)
			h.app.openProjectMenu()
			h.settle()
			hit, ok := h.findPageHit(h.app.text.Welcome.MenuRemove)
			if !ok {
				t.Fatal("recent project has no remove X")
			}
			h.click(center(hit.Bounds))
			h.settle()
			if h.app.project != p || !h.app.title.projectOpen {
				t.Fatal("removing recent switched project or closed menu")
			}
			if slices.ContainsFunc(h.app.recent, func(entry core.RecentProject) bool { return entry.Path == path }) {
				t.Fatal("recent record remains")
			}
			var saved []core.RecentProject
			if _, err := h.store.Load(recentFile, &saved); err != nil {
				t.Fatal(err)
			}
			if slices.ContainsFunc(saved, func(entry core.RecentProject) bool { return entry.Path == path }) {
				t.Fatal("removed record was not persisted")
			}
			if !missing {
				if info, err := os.Stat(path); err != nil || !info.IsDir() {
					t.Fatalf("project folder was removed: %v", err)
				}
			}
			h.clickNamed(h.app.text.Title.CloseProject)
			h.settle()
			if h.app.project != nil {
				t.Fatal("open project's X no longer closes it")
			}
			if !slices.ContainsFunc(h.app.recent, func(entry core.RecentProject) bool { return entry.Path == p.root }) {
				t.Fatal("closing project also erased recent record")
			}
		})
	}
}
