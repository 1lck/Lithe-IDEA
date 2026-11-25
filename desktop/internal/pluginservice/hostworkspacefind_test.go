package pluginservice

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

func TestWorkspaceSearchPublishesDiskResourcesAndContinuation(t *testing.T) {
	service := openHostService(t)
	if err := service.AttachWorkbench(diskReadWorkbench{&fakeWorkbench{}, core.NewClient()}); err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	for _, name := range []string{"a.txt", "b.txt"} {
		if err := os.WriteFile(filepath.Join(root, name), []byte("alpha\nBETA\n"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	workspace := service.Contexts.Open(root)
	t.Cleanup(func() { service.Contexts.Close(root) })
	rootID := service.Contexts.RootID("a", root)
	request := map[string]any{"context": workspace.ContextRef, "resource": Resource{rootID, ""}, "query": ".txt", "limit": 1}
	var paths []string
	for range 2 {
		body, _ := json.Marshal(request)
		result, refusal := respond(t, service, "a", "workspace/findFiles", string(body))
		var page struct {
			Matches     []Resource
			NextCursor  *string
			Source      string
			IsTruncated bool
		}
		if err := json.Unmarshal(result, &page); err != nil || refusal != nil || len(page.Matches) != 1 || page.Source != "disk" || page.IsTruncated {
			t.Fatalf("page = %s, %+v, %v", result, refusal, err)
		}
		if page.Matches[0].RootID != rootID {
			t.Fatalf("resource = %+v", page.Matches[0])
		}
		paths = append(paths, page.Matches[0].Path)
		request["cursor"] = page.NextCursor
	}
	if paths[0] != "a.txt" || paths[1] != "b.txt" {
		t.Fatalf("paths = %v", paths)
	}
	text := map[string]any{"context": workspace.ContextRef, "resource": Resource{rootID, ""}, "pattern": "beta", "fileMask": "a.*", "wholeWords": true}
	body, _ := json.Marshal(text)
	result, refusal := respond(t, service, "a", "workspace/findText", string(body))
	var page struct {
		Matches []struct {
			Resource Resource
			Line     int
			Preview  string
			Range    json.RawMessage
		}
	}
	if err := json.Unmarshal(result, &page); err != nil || refusal != nil || len(page.Matches) != 1 {
		t.Fatalf("text = %s, %+v, %v", result, refusal, err)
	}
	if hit := page.Matches[0]; hit.Resource != (Resource{rootID, "a.txt"}) || hit.Line != 2 || hit.Preview != "BETA" || string(hit.Range) != "null" {
		t.Fatalf("hit = %+v", hit)
	}
	text["pattern"], text["regularExpression"] = "[", true
	body, _ = json.Marshal(text)
	if _, refusal := respond(t, service, "a", "workspace/findText", string(body)); refusal == nil || refusal.Code != codeInvalidParams {
		t.Fatalf("invalid regex = %+v", refusal)
	}
	if _, refusal := respond(t, service, "b", "workspace/findText", string(body)); refusal == nil || refusal.Code != codeInvalidParams {
		t.Fatalf("foreign root = %+v", refusal)
	}
}
