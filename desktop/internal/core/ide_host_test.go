package core

import (
	"path/filepath"
	"testing"
)

// The broker tests run against the real Core. Open needs a helper file that
// exists, so each test puts a placeholder at helperPath and uses a temp directory.
func TestIDEHostCatalogAndValidate(t *testing.T) {
	client := NewClient()
	catalog, err := client.IDEHostCatalog(testContext(t), nil)
	if err != nil || catalog.Version != 1 || len(catalog.Tools) == 0 {
		t.Fatalf("catalog = %#v, %v", catalog, err)
	}
	read, err := client.IDEHostValidate(testContext(t), "lithe_project_inspect", map[string]any{}, IDEPermissions{}, nil)
	if err != nil || !read.OK || read.Mutation {
		t.Fatalf("read validate = %#v, %v", read, err)
	}
	denied, err := client.IDEHostValidate(testContext(t), "lithe_run_start", map[string]any{"configurationID": "x"}, IDEPermissions{}, nil)
	if err != nil {
		t.Fatal(err)
	}
	if denied.OK || denied.Error == nil || denied.Error.Code != "PERMISSION_DENIED" {
		t.Fatalf("execute without grant = %#v", denied)
	}
}

func TestIDEHostOpenPollClose(t *testing.T) {
	client := NewClient()
	dir := t.TempDir()
	helper := filepath.Join(dir, "lithe-mcp")
	writeFile(t, helper, "")
	opened, err := client.IDEHostOpen(testContext(t), IDEHostOpenRequest{
		Directory:    filepath.Join(dir, "ide-host"),
		WorkspaceKey: "test-workspace",
		HelperPath:   helper,
		Permissions:  IDEPermissions{},
	})
	if err != nil || opened.HostID == "" || len(opened.Configuration) == 0 {
		t.Fatalf("open = %#v, %v", opened, err)
	}
	poll, err := client.IDEHostPoll(testContext(t), opened.HostID)
	if err != nil || len(poll.Requests) != 0 {
		t.Fatalf("poll = %#v, %v", poll, err)
	}
	closed, err := client.IDEHostClose(testContext(t), opened.HostID)
	if err != nil || !closed.Closed {
		t.Fatalf("close = %#v, %v", closed, err)
	}
}
