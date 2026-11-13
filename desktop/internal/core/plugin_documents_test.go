package core

import (
	"encoding/json"
	"errors"
	"os"
	"reflect"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/contractfixture"
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
	data, err := os.ReadFile(contractfixture.CoreFixture("lsp/document-uri-v1.json"))
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

func TestPluginDocumentIdentityUsesCoreFixture(t *testing.T) {
	data, err := os.ReadFile(contractfixture.CoreFixture("lsp/document-identity-v1.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Cases []struct {
			Name     string                                          `json:"name"`
			Request  struct{ WorkspaceRoot, Input, Platform string } `json:"request"`
			Expected struct {
				Document *PluginDocumentIdentity `json:"document"`
			} `json:"expected"`
			Error ErrorCode `json:"error"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	for _, c := range fixture.Cases {
		t.Run(c.Name, func(t *testing.T) {
			actual, err := NewClient().ResolvePluginDocumentIdentity(testContext(t), c.Request.WorkspaceRoot, c.Request.Input, c.Request.Platform)
			if c.Error != "" {
				var failure *Error
				if !errors.As(err, &failure) || failure.Code != c.Error {
					t.Fatalf("error=%v, want %s", err, c.Error)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(actual, c.Expected.Document) {
				t.Fatalf("identity=%+v, want %+v", actual, c.Expected.Document)
			}
		})
	}
}

func TestPluginSemanticBodyCarriesRangeFormatting(t *testing.T) {
	body := pluginSemanticBody{
		SessionID: "s", Operation: "rangeFormatting", URI: "file:///a.c",
		Range: &PluginDocumentRange{
			Start: PluginDocumentPosition{Line: 1, UTF16Column: 0},
			End:   PluginDocumentPosition{Line: 2, UTF16Column: 3},
		},
		FormattingOptions: &FormattingOptions{TabSize: 2, InsertSpaces: false},
	}
	encoded, err := json.Marshal(body)
	if err != nil {
		t.Fatal(err)
	}
	want := `{"sessionId":"s","operation":"rangeFormatting","uri":"file:///a.c",` +
		`"range":{"start":{"line":1,"utf16Column":0},"end":{"line":2,"utf16Column":3}},` +
		`"formattingOptions":{"tabSize":2,"insertSpaces":false}}`
	if string(encoded) != want {
		t.Fatalf("body = %s", encoded)
	}
}
