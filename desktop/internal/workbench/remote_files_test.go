package workbench

import (
	"context"
	"path"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// remoteHostFileOps records file management calls on remoteHostKernel and tracks virtual
// directories so RemoteMakeDirectory, RemoteRename, RemoteCopy, RemoteTrash and RemoteRemove
// keep k.tree in sync with the host state.
type remoteHostFileOps struct {
	enabled bool
	dirs    map[string]bool
	created []string
	renamed [][2]string
	copied  [][2]string
	trashed []string
	removed []string
}

func remoteAlreadyExistsError(command string) error {
	return &core.Error{
		Command: command,
		Code:    core.CodeProcessFailed,
		Message: "the target already exists",
		Details: `{"remoteCode":"ALREADY_EXISTS"}`,
	}
}

// initRemoteFS initializes k with a mutable virtual host filesystem rooted at remoteTestFolder
// so project tree listings reflect every create, mkdir, rename, copy, trash and remove.
func (k *remoteHostKernel) initRemoteFS(files map[string]string, dirs ...string) {
	k.set(func(k *remoteHostKernel) {
		k.fsOps.enabled = true
		k.fsOps.dirs = map[string]bool{remoteTestFolder: true}
		for _, d := range dirs {
			k.fsOps.dirs[path.Join(remoteTestFolder, d)] = true
		}
		k.files = map[string][]byte{}
		k.modified = map[string]int64{}
		for rel, content := range files {
			full := path.Join(remoteTestFolder, rel)
			k.writeLocked(full, []byte(content))
			for cur := path.Dir(full); strings.HasPrefix(cur, remoteTestFolder); cur = path.Dir(cur) {
				k.fsOps.dirs[cur] = true
				if cur == remoteTestFolder {
					break
				}
			}
		}
		k.syncRemoteTreeLocked()
	})
}

func (k *remoteHostKernel) existsLocked(hostPath string) bool {
	if _, ok := k.files[hostPath]; ok {
		return true
	}
	return k.fsOps.dirs[hostPath]
}

// syncRemoteTreeLocked rebuilds k.tree from k.files and k.fsOps.dirs when fsOps is enabled.
func (k *remoteHostKernel) syncRemoteTreeLocked() {
	if !k.fsOps.enabled {
		return
	}
	byDir := map[string]map[string]core.WorkspaceNode{}
	add := func(parentRel string, node core.WorkspaceNode) {
		if byDir[parentRel] == nil {
			byDir[parentRel] = map[string]core.WorkspaceNode{}
		}
		byDir[parentRel][node.Path] = node
	}
	relOf := func(hostPath string) (string, bool) {
		if hostPath == remoteTestFolder {
			return "", true
		}
		if rest, ok := strings.CutPrefix(hostPath, remoteTestFolder+"/"); ok {
			return rest, true
		}
		return "", false
	}
	for dir := range k.fsOps.dirs {
		rel, ok := relOf(dir)
		if !ok || rel == "" {
			continue
		}
		parent := path.Dir(rel)
		if parent == "." {
			parent = ""
		}
		add(parent, core.WorkspaceNode{Path: rel, Name: path.Base(rel), IsDirectory: true})
	}
	for file := range k.files {
		rel, ok := relOf(file)
		if !ok || rel == "" {
			continue
		}
		parent := path.Dir(rel)
		if parent == "." {
			parent = ""
		}
		add(parent, core.WorkspaceNode{Path: rel, Name: path.Base(rel)})
	}
	tree := map[string][]core.WorkspaceNode{"": nil}
	for dir := range k.fsOps.dirs {
		if rel, ok := relOf(dir); ok {
			tree[rel] = nil
		}
	}
	for dir, entries := range byDir {
		nodes := make([]core.WorkspaceNode, 0, len(entries))
		for _, n := range entries {
			nodes = append(nodes, n)
		}
		slices.SortFunc(nodes, func(a, b core.WorkspaceNode) int {
			if a.IsDirectory != b.IsDirectory {
				if a.IsDirectory {
					return -1
				}
				return 1
			}
			return strings.Compare(a.Name, b.Name)
		})
		tree[dir] = nodes
	}
	k.tree = tree
}

func (k *remoteHostKernel) RemoteMakeDirectory(_ context.Context, session, hostPath string) error {
	k.mu.Lock()
	defer k.mu.Unlock()
	if err := k.takeFileError(session); err != nil {
		return err
	}
	if k.existsLocked(hostPath) {
		return remoteAlreadyExistsError("remote.hostRequest")
	}
	if k.fsOps.dirs == nil {
		k.fsOps.dirs = map[string]bool{}
	}
	k.fsOps.dirs[hostPath] = true
	k.fsOps.created = append(k.fsOps.created, hostPath)
	k.syncRemoteTreeLocked()
	return nil
}

func (k *remoteHostKernel) RemoteRename(_ context.Context, session, from, to string, overwrite bool) error {
	k.mu.Lock()
	defer k.mu.Unlock()
	if err := k.takeFileError(session); err != nil {
		return err
	}
	if !overwrite && k.existsLocked(to) {
		return remoteAlreadyExistsError("remote.hostRequest")
	}
	if !k.existsLocked(from) {
		return &core.Error{Command: "remote.hostRequest", Code: core.CodeWorkspaceNotFound, Message: "no such file"}
	}
	if data, ok := k.files[from]; ok {
		delete(k.files, from)
		k.writeLocked(to, data)
	}
	if k.fsOps.dirs[from] {
		delete(k.fsOps.dirs, from)
		k.fsOps.dirs[to] = true
		prefix := from + "/"
		var moveFiles []string
		for name := range k.files {
			if strings.HasPrefix(name, prefix) {
				moveFiles = append(moveFiles, name)
			}
		}
		for _, name := range moveFiles {
			data := k.files[name]
			delete(k.files, name)
			k.writeLocked(to+"/"+strings.TrimPrefix(name, prefix), data)
		}
		var moveDirs []string
		for dir := range k.fsOps.dirs {
			if strings.HasPrefix(dir, prefix) {
				moveDirs = append(moveDirs, dir)
			}
		}
		for _, dir := range moveDirs {
			delete(k.fsOps.dirs, dir)
			k.fsOps.dirs[to+"/"+strings.TrimPrefix(dir, prefix)] = true
		}
	}
	k.fsOps.renamed = append(k.fsOps.renamed, [2]string{from, to})
	k.syncRemoteTreeLocked()
	return nil
}

func (k *remoteHostKernel) RemoteCopy(_ context.Context, session, from, to string, _, overwrite bool) error {
	k.mu.Lock()
	defer k.mu.Unlock()
	if err := k.takeFileError(session); err != nil {
		return err
	}
	if !overwrite && k.existsLocked(to) {
		return remoteAlreadyExistsError("remote.hostRequest")
	}
	if !k.existsLocked(from) {
		return &core.Error{Command: "remote.hostRequest", Code: core.CodeWorkspaceNotFound, Message: "no such file"}
	}
	if data, ok := k.files[from]; ok {
		k.writeLocked(to, data)
	}
	if k.fsOps.dirs[from] {
		if k.fsOps.dirs == nil {
			k.fsOps.dirs = map[string]bool{}
		}
		k.fsOps.dirs[to] = true
		prefix := from + "/"
		var copyFiles []string
		for name := range k.files {
			if strings.HasPrefix(name, prefix) {
				copyFiles = append(copyFiles, name)
			}
		}
		for _, name := range copyFiles {
			k.writeLocked(to+"/"+strings.TrimPrefix(name, prefix), k.files[name])
		}
		var copyDirs []string
		for dir := range k.fsOps.dirs {
			if strings.HasPrefix(dir, prefix) {
				copyDirs = append(copyDirs, dir)
			}
		}
		for _, dir := range copyDirs {
			k.fsOps.dirs[to+"/"+strings.TrimPrefix(dir, prefix)] = true
		}
	}
	k.fsOps.copied = append(k.fsOps.copied, [2]string{from, to})
	k.syncRemoteTreeLocked()
	return nil
}

func (k *remoteHostKernel) RemoteTrash(_ context.Context, session, hostPath string) error {
	k.mu.Lock()
	defer k.mu.Unlock()
	if err := k.takeFileError(session); err != nil {
		return err
	}
	if !k.existsLocked(hostPath) {
		return &core.Error{Command: "remote.hostRequest", Code: core.CodeWorkspaceNotFound, Message: "no such file"}
	}
	delete(k.files, hostPath)
	delete(k.fsOps.dirs, hostPath)
	prefix := hostPath + "/"
	for name := range k.files {
		if strings.HasPrefix(name, prefix) {
			delete(k.files, name)
		}
	}
	for dir := range k.fsOps.dirs {
		if strings.HasPrefix(dir, prefix) {
			delete(k.fsOps.dirs, dir)
		}
	}
	k.fsOps.trashed = append(k.fsOps.trashed, hostPath)
	k.syncRemoteTreeLocked()
	return nil
}

// TestRemoteProjectTreeMenuParity verifies that a remote workspace's Project tree context menu
// exposes the same file management, search, copy-path, Open In -> Terminal and refresh items as a
// local workspace while omitting strictly local-only entries (Local History, local search
// exclusions, Open With and local file manager).
func TestRemoteProjectTreeMenuParity(t *testing.T) {
	h, k, _, _ := remoteWorkspaceHarness(t)
	k.initRemoteFS(map[string]string{
		"README.md":   "# Remote\n",
		"src/main.go": "package main\n",
	}, "src")
	h.openRemoteTestProject(t)

	// File row context menu.
	h.rightClickNamed("README.md")
	for _, key := range []string{
		"desktop.files.open",
		"native.findInFiles",
		"desktop.command.replaceInFiles",
		"desktop.files.cut",
		"desktop.files.copy",
		"desktop.files.duplicate",
		"desktop.files.rename",
		"desktop.files.delete",
		"native.copyPathReference",
		"desktop.files.openIn",
		"desktop.files.refresh",
	} {
		if !h.hasPopupItem(h.shared(key)) {
			t.Fatalf("remote file menu missing %q (%s)", h.shared(key), key)
		}
	}
	if h.hasPopupItem(h.shared("desktop.history.show")) {
		t.Fatal("remote file menu should not show Local History")
	}
	// Open In submenu on remote has Terminal, not Open With or Finder/Explorer.
	h.click(center(h.popupHit(h.shared("desktop.files.openIn"))))
	h.settle()
	if !h.hasPopupItem(h.shared("desktop.files.openInTerminal")) {
		t.Fatal("remote Open In submenu missing Terminal")
	}
	if h.hasPopupItem(h.shared("desktop.files.openWith")) {
		t.Fatal("remote Open In submenu should not show Open With")
	}
	if h.hasPopupItem(fileManagerLabel(h.app.language())) {
		t.Fatal("remote Open In submenu should not show local file manager")
	}

	// Folder row context menu.
	h.rightClickNamed("src")
	for _, key := range []string{
		"native.findInFiles",
		"desktop.command.replaceInFiles",
		"native.new",
		"desktop.files.cut",
		"desktop.files.copy",
		"desktop.files.duplicate",
		"desktop.files.rename",
		"desktop.files.delete",
		"native.copyPathReference",
		"desktop.files.openIn",
		"desktop.files.refresh",
	} {
		if !h.hasPopupItem(h.shared(key)) {
			t.Fatalf("remote folder menu missing %q (%s)", h.shared(key), key)
		}
	}
	if h.hasPopupItem(h.shared("desktop.files.excludeFromSearch")) {
		t.Fatal("remote folder menu should not show Exclude from Search")
	}
}

// TestRemoteProjectTreeCreateRenameDuplicatePasteAndDelete exercises every remote file operation
// through the host RPCs and verifies open document tabs follow renames/moves and close on delete.
func TestRemoteProjectTreeCreateRenameDuplicatePasteAndDelete(t *testing.T) {
	h, k, _, _ := remoteWorkspaceHarness(t)
	k.initRemoteFS(map[string]string{
		"README.md":   "# Remote\n",
		"src/main.go": "package main\n",
	}, "src")
	p := h.openRemoteTestProject(t)

	// Expand src so src/main.go is loaded.
	h.app.listTree(p, "src")
	h.await("src/main.go listed", func() bool { return p.tree.find("src/main.go") != nil })

	// 1. Create New Directory in src.
	src := p.tree.find("src")
	treePromptFor(h, p, treePromptNewDirectory, src, "pkg")
	h.app.submitTreePrompt(p)
	h.await("new remote directory pkg", func() bool {
		return p.tree.find("src/pkg") != nil && !p.tree.prompt.open
	})
	// Duplicate directory name is rejected inside the dialog.
	treePromptFor(h, p, treePromptNewDirectory, src, "pkg")
	h.app.submitTreePrompt(p)
	h.await("duplicate directory rejected", func() bool {
		return !p.tree.prompt.busy && p.tree.prompt.err == h.shared("desktop.files.nameExists") && p.tree.prompt.open
	})
	p.tree.prompt.open = false

	// 2. Create New File in src/pkg; it opens in a tab.
	pkg := p.tree.find("src/pkg")
	treePromptFor(h, p, treePromptNewFile, pkg, "hello.go")
	h.app.submitTreePrompt(p)
	helloPlaceholder := filepath.Join(p.root, "src", "pkg", "hello.go")
	h.await("new remote file created and opened", func() bool {
		_, exists := k.file(remoteTestFolder + "/src/pkg/hello.go")
		return exists && p.docs.byPath(helloPlaceholder) != nil
	})

	// 3. Rename open file hello.go -> greet.go; its tab moves and no local watch is installed.
	h.app.listTree(p, "src/pkg")
	h.await("src/pkg/hello.go listed", func() bool { return p.tree.find("src/pkg/hello.go") != nil })
	helloNode := p.tree.find("src/pkg/hello.go")
	treePromptFor(h, p, treePromptRename, helloNode, "greet.go")
	h.app.submitTreePrompt(p)
	greetPlaceholder := filepath.Join(p.root, "src", "pkg", "greet.go")
	h.await("remote file renamed and tab moved", func() bool {
		_, exists := k.file(remoteTestFolder + "/src/pkg/greet.go")
		d := p.docs.byPath(greetPlaceholder)
		return exists && d != nil && d.name == "greet.go" && p.docs.byPath(helloPlaceholder) == nil
	})
	if len(p.docs.watches) != 0 {
		t.Fatalf("remote rename installed %d local document watches, want 0", len(p.docs.watches))
	}

	// 4. Duplicate README.md twice -> README copy.md, then README copy 2.md.
	readme := p.tree.find("README.md")
	h.app.duplicateTreeItem(p, readme)
	h.await("first remote duplicate", func() bool {
		_, ok := k.file(remoteTestFolder + "/README copy.md")
		return ok
	})
	h.app.duplicateTreeItem(p, readme)
	h.await("second remote duplicate", func() bool {
		_, ok := k.file(remoteTestFolder + "/README copy 2.md")
		return ok
	})

	// 5. Cut and paste greet.go into src; open tab moves to src/greet.go.
	h.app.listTree(p, "src/pkg")
	h.await("src/pkg/greet.go listed", func() bool { return p.tree.find("src/pkg/greet.go") != nil })
	h.app.treeCut(p, p.tree.find("src/pkg/greet.go"))
	h.app.treePaste(p, p.tree.find("src"))
	movedPlaceholder := filepath.Join(p.root, "src", "greet.go")
	h.await("cut and pasted remote file", func() bool {
		_, ok := k.file(remoteTestFolder + "/src/greet.go")
		return ok && p.docs.byPath(movedPlaceholder) != nil && p.docs.byPath(greetPlaceholder) == nil
	})

	// 6. Copy and paste README.md into src.
	h.app.treeCopy(p, p.tree.find("README.md"))
	h.app.treePaste(p, p.tree.find("src"))
	h.await("copied remote file into src", func() bool {
		_, ok := k.file(remoteTestFolder + "/src/README.md")
		return ok
	})

	// 7. Move to Trash on src/greet.go closes its tab and calls RemoteTrash.
	h.app.removeTreeItems(p, []string{"src/greet.go"}, false)
	h.await("trashed remote file and closed tab", func() bool {
		_, exists := k.file(remoteTestFolder + "/src/greet.go")
		return !exists && p.docs.byPath(movedPlaceholder) == nil
	})
	k.mu.Lock()
	trashed := slices.Clone(k.fsOps.trashed)
	k.mu.Unlock()
	if !slices.Contains(trashed, remoteTestFolder+"/src/greet.go") {
		t.Fatalf("RemoteTrash calls = %v, want %s", trashed, remoteTestFolder+"/src/greet.go")
	}

	// 8. Delete Permanently on src/README.md calls RemoteRemove.
	h.app.removeTreeItems(p, []string{"src/README.md"}, true)
	h.await("permanently removed remote file", func() bool {
		_, exists := k.file(remoteTestFolder + "/src/README.md")
		return !exists
	})
	k.mu.Lock()
	removed := slices.Clone(k.fsOps.removed)
	k.mu.Unlock()
	if !slices.Contains(removed, remoteTestFolder+"/src/README.md") {
		t.Fatalf("RemoteRemove calls = %v, want %s", removed, remoteTestFolder+"/src/README.md")
	}

	// 9. Drag-and-drop move (moveTreeItem) moves README copy.md into src.
	h.app.moveTreeItem(p, "README copy.md", "src")
	h.await("moved remote file into src", func() bool {
		_, moved := k.file(remoteTestFolder + "/src/README copy.md")
		_, oldExists := k.file(remoteTestFolder + "/README copy.md")
		return moved && !oldExists
	})

	// 10. Batch permanent delete removes multiple remote items.
	h.app.removeTreeItems(p, []string{"src/README copy.md", "README copy 2.md"}, true)
	h.await("batch removed remote files", func() bool {
		_, a := k.file(remoteTestFolder + "/src/README copy.md")
		_, b := k.file(remoteTestFolder + "/README copy 2.md")
		return !a && !b
	})

	// 11. Open In -> Terminal starts a remote terminal in the selected folder's host path.
	h.app.openTreeTerminal(p, filepath.Join(p.root, "src"))
	h.await("remote terminal opened in src", func() bool {
		k.terminals.mu.Lock()
		defer k.terminals.mu.Unlock()
		for _, run := range k.terminals.runs {
			if run.open.Cwd == remoteTestFolder+"/src" {
				return true
			}
		}
		return false
	})
}
