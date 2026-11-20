package toolchain

import (
	"context"
	"path/filepath"
	"runtime"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

func TestSourceRevisionKeepsProjectPinsLocal(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	kernel := core.NewClient()
	project, unrelated, global := t.TempDir(), t.TempDir(), t.TempDir()
	read := func(root string) SourceRevision {
		t.Helper()
		revision, err := ReadSourceRevision(ctx, kernel, root, global, PlatformName(runtime.GOOS))
		if err != nil {
			t.Fatal(err)
		}
		return revision
	}
	beforeProject, beforeUnrelated := read(project), read(unrelated)
	const tool = "dev.lithe.test.revision:runtime"
	if _, _, err := SavePin(ctx, kernel, project, ".", tool, &core.ToolchainPin{
		Home: filepath.ToSlash(t.TempDir()), Provider: "host:manual", Version: "1.0",
	}, nil); err != nil {
		t.Fatal(err)
	}
	if beforeProject.Equal(read(project)) || !beforeUnrelated.Equal(read(unrelated)) {
		t.Fatal("saving a pin must change only the owning project's source revision")
	}
}
