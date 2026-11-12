package workbench

import (
	"fmt"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// This measures a populated project tree during repeated workbench resizes;
// it does not include directory enumeration, rendering to the GPU or OS events.
func BenchmarkProjectTreeResize1000(b *testing.B) {
	h := newHarness(b, &testKernel{Client: core.NewClient()})
	h.open(b.TempDir())
	h.settle() // Finish the first real root listing before installing the fixed fixture.
	tree := &h.app.project.tree
	tree.root = &treeNode{name: "project", dir: true, expanded: true, listed: true}
	tree.byPath = nil
	tree.measureDirty = true
	for i := 0; i < 1000; i++ {
		tree.root.children = append(tree.root.children, tree.node(core.WorkspaceNode{Path: fmt.Sprintf("file-%04d.txt", i), Name: fmt.Sprintf("file-%04d.txt", i)}, 1))
	}
	if err := h.driver.Resize(1280, 720); err != nil {
		b.Fatal(err)
	}
	if err := h.driver.Advance(20 * time.Millisecond); err != nil {
		b.Fatal(err)
	}
	if len(tree.rows) != 1001 {
		b.Fatalf("benchmark tree has %d visible rows, want root and 1000 files", len(tree.rows))
	}
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if err := h.driver.Resize(1280+i%2, 720); err != nil {
			b.Fatal(err)
		}
	}
}
