package workbench

import (
	"context"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

type refusingTreeRenameKernel struct {
	*testKernel
	called atomic.Bool
}

func (k *refusingTreeRenameKernel) RenameWorkspaceEntry(context.Context, string, string, string) (core.WorkspaceEntry, error) {
	k.called.Store(true)
	return core.WorkspaceEntry{}, &core.Error{Command: "workspace.renameEntry", Code: core.CodeEntryExists}
}

// The destination is absent on disk. Only the injected workspace authority says
// the name is taken, so a successful move means the tree bypassed that authority.
func TestProjectTreeHonorsCoreRenameRefusal(t *testing.T) {
	for _, action := range []string{"rename", "move"} {
		t.Run(action, func(t *testing.T) {
			root := t.TempDir()
			writeTreeFiles(t, root, "source.txt", "folder/keep.txt")
			k := &refusingTreeRenameKernel{testKernel: &testKernel{Client: core.NewClient()}}
			h := newHarness(t, k)
			p := h.openTree(t, root)
			src := filepath.Join(root, "source.txt")
			tab := h.openTreeFileTab(p, src)
			target := "unused.txt"
			if action == "rename" {
				treePromptFor(h, p, treePromptRename, p.tree.find("source.txt"), target)
				h.app.submitTreePrompt(p)
			} else {
				target = "folder/source.txt"
				h.app.moveTreeItem(p, "source.txt", "folder")
			}
			dst := filepath.Join(root, filepath.FromSlash(target))
			// These actions bypass the input driver. Paint their result whether it
			// arrived synchronously or was posted by the workspace operation.
			h.app.invalidator.Invalidate()
			h.settleChain()
			if !k.called.Load() {
				t.Error("the project tree did not consult Core")
			}
			if !h.shows(h.shared("desktop.files.nameExists")) {
				t.Error("Core's entry_exists refusal was not shown as a name conflict")
			}
			expectTreeFileBytes(t, root, "source.txt", "source.txt\n")
			if _, err := os.Lstat(dst); !os.IsNotExist(err) {
				t.Errorf("destination %q should not exist after refusal, Lstat: %v", target, err)
			}
			if p.selectedDocument(p.docs.group) != tab || tab.path != src || p.docs.byPath(dst) != nil {
				t.Errorf("refused %s did not preserve the source tab at %q (tab path %q)", action, src, tab.path)
			}
		})
	}
}
