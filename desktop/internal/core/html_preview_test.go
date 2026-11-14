package core

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/contractfixture"
)

// TestHTMLPreviewSharedFixture: Core names the site of an HTML file and answers the site's
// requests as the shared fixture describes, for a page in the workspace, in a hidden folder and
// outside the workspace.
func TestHTMLPreviewSharedFixture(t *testing.T) {
	data, err := os.ReadFile(contractfixture.CoreFixture("editor/html-preview-v1.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Files []string
		Cases []struct {
			Name        string
			Document    string
			InWorkspace bool
			Site        struct{ Root, Address, MIME string }
			Requests    []struct{ Path, Kind, File, MIME string }
		}
		InvalidDocuments []string
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	if len(fixture.Cases) == 0 {
		t.Fatal("the fixture has no cases")
	}
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	under := func(relative string) string { return filepath.Join(root, filepath.FromSlash(relative)) }
	for _, entry := range fixture.Files {
		path := under(entry)
		if strings.HasSuffix(entry, "/") {
			if err := os.MkdirAll(path, 0o700); err != nil {
				t.Fatal(err)
			}
			continue
		}
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte("x"), 0o600); err != nil {
			t.Fatal(err)
		}
	}

	client := NewClient()
	for _, c := range fixture.Cases {
		t.Run(c.Name, func(t *testing.T) {
			document, workspace := under(c.Document), ""
			if c.InWorkspace {
				workspace = root
			}
			site, err := client.HTMLPreviewSite(testContext(t), document, workspace)
			if err != nil {
				t.Fatal(err)
			}
			if want := (HTMLPreviewSite{Root: under(c.Site.Root), Address: c.Site.Address, MIME: c.Site.MIME}); site != want {
				t.Fatalf("the site is %+v, want %+v", site, want)
			}
			for _, request := range c.Requests {
				got, err := client.ResolveHTMLPreviewRequest(testContext(t), document, workspace, request.Path)
				if err != nil {
					t.Fatal(err)
				}
				want := HTMLPreviewResource{Kind: request.Kind}
				if request.File != "" {
					want.Path, want.MIME = under(request.File), request.MIME
				}
				if got != want {
					t.Errorf("%q is %+v, want %+v", request.Path, got, want)
				}
			}
		})
	}
	for _, document := range fixture.InvalidDocuments {
		if _, err := client.HTMLPreviewSite(testContext(t), document, ""); err == nil {
			t.Errorf("%q was given a site", document)
		}
	}
}
