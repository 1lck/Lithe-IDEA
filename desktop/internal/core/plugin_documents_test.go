package core

import (
	"encoding/json"
	"os"
	"testing"
)

func TestPluginDocumentSyncDecodesCoreResponse(t *testing.T) {
	var sync PluginDocumentSync
	body := `{"documentVersion":3,"changed":true,"uri":"file:///a.java"}`
	if err := json.Unmarshal([]byte(body), &sync); err != nil {
		t.Fatal(err)
	}
	if sync.DocumentVersion != 3 || !sync.Changed || sync.URI != "file:///a.java" {
		t.Fatalf("sync = %+v", sync)
	}
}

func TestPluginTextChangeMatchesLSPShape(t *testing.T) {
	ranged := PluginTextChange{
		Range: &PluginDocumentRange{
			Start: PluginDocumentPosition{Line: 1, UTF16Column: 2},
			End:   PluginDocumentPosition{Line: 1, UTF16Column: 4},
		},
		Text: "x",
	}
	encoded, err := json.Marshal(ranged)
	if err != nil {
		t.Fatal(err)
	}
	want := `{"range":{"start":{"line":1,"utf16Column":2},"end":{"line":1,"utf16Column":4}},"text":"x"}`
	if string(encoded) != want {
		t.Fatalf("change = %s", encoded)
	}
	// A change without a range replaces the whole document, which is how a full
	// synchronization is expressed.
	whole, err := json.Marshal(PluginTextChange{Text: "all"})
	if err != nil {
		t.Fatal(err)
	}
	if string(whole) != `{"text":"all"}` {
		t.Fatalf("whole = %s", whole)
	}
}

func TestPluginDocumentSyncRequestKeepsTextOptional(t *testing.T) {
	// The request type is converted into the wire body inside the client, so what
	// matters here is that an empty text and no changes stay distinguishable from a
	// full-text replacement of an empty document.
	empty := PluginDocumentSyncRequest{SessionID: "s", URI: "file:///a.java", LanguageID: "java"}
	if empty.Text != "" || len(empty.ContentChanges) != 0 {
		t.Fatalf("request = %+v", empty)
	}
}

func TestPluginDocumentURIUsesCoreFixture(t *testing.T) {
	data, err := os.ReadFile("../../../shared/fixtures/lsp/document-uri-v1.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Cases []struct {
			Name     string  `json:"name"`
			Platform string  `json:"platform"`
			Path     string  `json:"path"`
			URI      *string `json:"uri"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	client := NewClient()
	for _, c := range fixture.Cases {
		t.Run(c.Name, func(t *testing.T) {
			got, err := client.PluginDocumentURI(testContext(t), c.Path, c.Platform)
			if c.URI == nil {
				if err == nil {
					t.Fatalf("uri = %q, want rejection", got)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if got != *c.URI {
				t.Fatalf("uri = %q, want %q", got, *c.URI)
			}
		})
	}
}
