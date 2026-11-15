package workbench

import (
	"context"
	"crypto/sha256"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"runtime"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/app"
)

// The child executes the production workbench from inside an isolated package
// fixture. Hashes cover both its executable and resources before and after.
func TestInstalledResourcesStayUnchanged(t *testing.T) {
	if os.Getenv("LITHE_BUNDLE_TEST_CHILD") == "1" {
		exercisePackagedWorkbench(t)
		return
	}
	root := filepath.Join(t.TempDir(), "Lithe.app", "Contents")
	bin, resources := filepath.Join(root, "MacOS", "lithe"), filepath.Join(root, "Resources")
	if runtime.GOOS == "windows" {
		root = filepath.Join(t.TempDir(), "Lithe")
		bin, resources = filepath.Join(root, "lithe.exe"), filepath.Join(root, "resources")
	}
	if err := os.MkdirAll(filepath.Dir(bin), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(resources, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(resources, "fixed-resource.txt"), []byte("packaged resource\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	source, err := os.Open(executable)
	if err != nil {
		t.Fatal(err)
	}
	destination, err := os.OpenFile(bin, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o700)
	if err != nil {
		source.Close()
		t.Fatal(err)
	}
	_, copyErr := io.Copy(destination, source)
	closeErr := destination.Close()
	readCloseErr := source.Close()
	if copyErr != nil || closeErr != nil || readCloseErr != nil {
		t.Fatalf("copy executable: %v, close output: %v, close input: %v", copyErr, closeErr, readCloseErr)
	}
	before := bundleFileHashes(t, root)
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	command := exec.CommandContext(ctx, bin, "-test.run=^TestInstalledResourcesStayUnchanged$", "-test.timeout=30s")
	command.Env = append(os.Environ(), "LITHE_BUNDLE_TEST_CHILD=1")
	if output, err := command.CombinedOutput(); err != nil {
		t.Fatalf("packaged workbench: %v\n%s", err, output)
	}
	after := bundleFileHashes(t, root)
	if !reflect.DeepEqual(before, after) {
		t.Fatalf("installed files changed during workbench use: before=%v after=%v", before, after)
	}
}

func bundleFileHashes(t *testing.T, root string) map[string][32]byte {
	t.Helper()
	hashes := make(map[string][32]byte)
	err := filepath.WalkDir(root, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.IsDir() {
			return nil
		}
		if !entry.Type().IsRegular() {
			return fmt.Errorf("unexpected non-regular package entry %s", path)
		}
		file, err := os.Open(path)
		if err != nil {
			return err
		}
		hash := sha256.New()
		_, copyErr := io.Copy(hash, file)
		closeErr := file.Close()
		if copyErr != nil {
			return copyErr
		}
		if closeErr != nil {
			return closeErr
		}
		rel, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		var digest [32]byte
		copy(digest[:], hash.Sum(nil))
		hashes[rel] = digest
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return hashes
}

func exercisePackagedWorkbench(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.app.searchView.delay = 0
	root := t.TempDir()
	path := filepath.Join(root, "example.txt")
	if err := os.WriteFile(path, []byte("searchable text\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	h.open(root)
	p := h.app.project
	h.app.openFile(p, path)
	awaitDocumentState(t, h, func() bool { return p.docs.byPath(path) != nil })
	doc := p.docs.byPath(path)
	input := doc.view.TextInput(app.TextInputContext{ID: doc.hit})
	if _, err := input.OnEvent(app.TextEvent{Kind: app.TextInsert, Text: "updated "}); err != nil {
		t.Fatal(err)
	}
	previousNotice := h.app.notice
	h.app.saveDocument(p, doc.id)
	awaitDocumentState(t, h, func() bool { return !doc.dirty() || (!doc.saving && h.app.notice != previousNotice) })
	if doc.dirty() {
		t.Fatalf("packaged workbench could not save the document: %s", h.app.notice)
	}
	h.click(center(h.button(itemFind)))
	h.app.searchView.query.SetText("searchable")
	h.app.invalidator.Invalidate()
	if err := h.driver.Pump(); err != nil {
		t.Fatal(err)
	}
	awaitDocumentState(t, h, func() bool { return !p.search.loading && len(p.search.matches) > 0 })
	h.app.everywhereView.delay = 0
	h.app.openEverywhere(p)
	h.app.everywhereView.query.SetText("example")
	h.app.invalidator.Invalidate()
	if err := h.driver.Pump(); err != nil {
		t.Fatal(err)
	}
	awaitDocumentState(t, h, func() bool { return !p.everywhere.loading && len(p.everywhere.matches) > 0 })
}
