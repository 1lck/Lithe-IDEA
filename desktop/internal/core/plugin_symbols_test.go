package core

import (
	"encoding/json"
	"os"
	"testing"
)

func TestPluginDocumentSymbolsSharedFixtures(t *testing.T) {
	data, err := os.ReadFile("../../../shared/fixtures/lsp/document-symbols-v1.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Cases []struct {
			Name     string
			Expected json.RawMessage
		}
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	if len(fixture.Cases) == 0 {
		t.Fatal("fixture has no cases")
	}
	for _, c := range fixture.Cases {
		t.Run(c.Name, func(t *testing.T) {
			symbols, err := PluginDocumentSymbols(BackendEvent{Result: c.Expected})
			if err != nil {
				t.Fatal(err)
			}
			again, err := json.Marshal(struct {
				Symbols []DocumentSymbol `json:"symbols"`
			}{symbols})
			if err != nil {
				t.Fatal(err)
			}
			var got, want any
			_ = json.Unmarshal(again, &got)
			_ = json.Unmarshal(c.Expected, &want)
			gj, _ := json.Marshal(got)
			wj, _ := json.Marshal(want)
			if string(gj) != string(wj) {
				t.Fatalf("round trip differs\n got %s\nwant %s", gj, wj)
			}
		})
	}
}

func TestPluginSemanticTokensSharedFixture(t *testing.T) {
	data, err := os.ReadFile("../../../shared/fixtures/lsp/semantic-tokens-v1.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		ExpectedResult json.RawMessage `json:"expectedResult"`
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	tokens, err := PluginSemanticTokens(BackendEvent{Result: fixture.ExpectedResult})
	if err != nil {
		t.Fatal(err)
	}
	if len(tokens.TokenTypes) != 2 || len(tokens.Tokens) != 3 || tokens.Tokens[0].TokenModifiers != 1 || tokens.Tokens[2].StartChar != 11 {
		t.Fatalf("tokens = %+v", tokens)
	}
}
