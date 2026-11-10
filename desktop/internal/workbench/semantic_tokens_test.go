package workbench

import (
	"encoding/json"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/syntax"
)

func tokensResult(t *testing.T) json.RawMessage {
	t.Helper()
	data, err := json.Marshal(core.SemanticTokens{
		TokenTypes: []string{"class"},
		Tokens:     []core.SemanticToken{{Line: 0, StartChar: 0, Length: 3, TokenType: 0}},
	})
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func TestSemanticTokensAreRequestedAfterEditAndLaidOverTheText(t *testing.T) {
	f := newSemanticFixture(t)
	f.server.features = map[string]bool{featureSemanticTokens: true}
	f.h.app.semanticTokensRefresh(f.server)
	f.d.sync.pluginID = "test"
	f.h.settle()
	f.waitForRequests(t, 1)
	if got := f.kernel.request(0).Operation; got != pluginSemanticTokens {
		t.Fatalf("operation = %q", got)
	}
	f.deliver(t, "op-1", pluginMethodSemanticTokens, tokensResult(t))
	f.h.settle()
	var tokens []syntax.Token
	tokens = f.d.view.SyntaxLine(tokens, 0)
	found := false
	for _, token := range tokens {
		if token.Name.String() == "class" {
			found = true
		}
	}
	if !found {
		t.Fatalf("line 0 tokens = %v", tokens)
	}
	// The same text asks for nothing more.
	f.h.app.semanticTokensResume()
	f.h.settle()
	if got := f.kernel.requestCount(); got != 1 {
		t.Fatalf("requests = %d, want 1", got)
	}
}

func TestSemanticTokensDroppedWithTheServer(t *testing.T) {
	f := newSemanticFixture(t)
	f.server.features = map[string]bool{featureSemanticTokens: true}
	f.d.sync.pluginID = "test"
	f.h.app.semanticTokensRefresh(f.server)
	f.h.settle()
	f.waitForRequests(t, 1)
	f.deliver(t, "op-1", pluginMethodSemanticTokens, tokensResult(t))
	f.h.settle()
	f.h.app.semanticTokensReleased("test")
	for _, token := range f.d.view.SyntaxLine(nil, 0) {
		if token.Name.String() == "class" {
			t.Fatal("semantic colors survived the server")
		}
	}
}
