package core

import (
	"encoding/json"
	"testing"
)

// Every provider type the host routes must pass Core's registration check with
// EditorHost.ProviderTypes, or a plugin's registration of it is refused before
// the host can present it. foldingRange has no editor surface yet, so Core must
// refuse it under the same list.
func TestEditorHostProviderTypesPassCoreRegistration(t *testing.T) {
	client, ctx := NewClient(), testContext(t)
	options := map[string]map[string]any{
		"completion":     {"function": "keys.completion", "triggerCharacters": []string{"."}},
		"semanticTokens": {"function": "keys.semanticTokens", "legend": map[string]any{"tokenTypes": []string{"property"}, "tokenModifiers": []string{}}},
	}
	for _, kind := range EditorHost.ProviderTypes {
		provider, ok := options[kind]
		if !ok {
			provider = map[string]any{"function": "keys." + kind}
		}
		payload := map[string]any{"kind": "registration", "types": EditorHost.ProviderTypes, "value": map[string]any{
			"id": "keys", "selector": map[string]any{"fileExtensions": []string{"properties"}},
			"providers": map[string]any{kind: provider},
		}}
		decoded, err := client.DecodeEditorProviders(ctx, payload)
		if err != nil {
			t.Fatalf("%s registration refused: %v", kind, err)
		}
		var result struct {
			Registration struct {
				Providers map[string]json.RawMessage `json:"providers"`
			} `json:"registration"`
		}
		if err := json.Unmarshal(decoded, &result); err != nil || result.Registration.Providers[kind] == nil {
			t.Fatalf("%s registration decoded to %s (%v)", kind, decoded, err)
		}
	}
	refused := map[string]any{"kind": "registration", "types": EditorHost.ProviderTypes, "value": map[string]any{
		"id": "keys", "selector": map[string]any{"fileExtensions": []string{"properties"}},
		"providers": map[string]any{"foldingRange": map[string]any{"function": "keys.folding"}},
	}}
	if _, err := client.DecodeEditorProviders(ctx, refused); err == nil {
		t.Fatal("an unrouted foldingRange registration was accepted")
	}
}
