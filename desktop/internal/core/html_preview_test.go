package core

import (
	"os"
	"path/filepath"
	"testing"
)

// TestHTMLPreviewSiteAndRequestsFromCore: Core names the workspace as the site of an HTML file in
// it, with the file's address and type, and answers the site's requests by kind.
func TestHTMLPreviewSiteAndRequestsFromCore(t *testing.T) {
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	for name, text := range map[string]string{
		"site/page one.html": "<link rel=stylesheet href=style.css>",
		"site/style.css":     "body{}",
		".git/config":        "[core]",
	} {
		path := filepath.Join(root, filepath.FromSlash(name))
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(text), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	document := filepath.Join(root, "site", "page one.html")
	client := NewClient()
	site, err := client.HTMLPreviewSite(testContext(t), document, root)
	if err != nil {
		t.Fatal(err)
	}
	if site.Root != root || site.Address != "site/page%20one.html" || site.MIME != "text/html; charset=utf-8" {
		t.Fatalf("the site is %+v", site)
	}
	for path, want := range map[string]HTMLPreviewResource{
		"site/page one.html": {Kind: "document"},
		"site/style.css":     {Kind: "file", Path: filepath.Join(root, "site", "style.css"), MIME: "text/css; charset=utf-8"},
		".git/config":        {Kind: "denied"},
		"site/missing.css":   {Kind: "none"},
		"../outside.html":    {Kind: "none"},
	} {
		got, err := client.ResolveHTMLPreviewRequest(testContext(t), document, root, path)
		if err != nil {
			t.Fatal(err)
		}
		if got != want {
			t.Fatalf("%q is %+v, want %+v", path, got, want)
		}
	}
	if _, err := client.HTMLPreviewSite(testContext(t), "page.html", ""); err == nil {
		t.Fatal("a relative path was given a site")
	}
}
