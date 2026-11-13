package pluginservice

import (
	"sort"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginbackend"
)

// A routed type without a binding field would be accepted and never called; a
// field whose type is not routed would be refused by Core. codeLens once had a
// field but no route, so its registrations never reached the editor.
func TestProviderFunctionFieldsMatchRoutedTypes(t *testing.T) {
	routed := append([]string(nil), routedProviderTypes...)
	sort.Strings(routed)
	fields := make([]string, 0, len(providerFunctionFields))
	for kind := range providerFunctionFields {
		fields = append(fields, kind)
	}
	sort.Strings(fields)
	if len(routed) != len(fields) {
		t.Fatalf("routed %v, fields %v", routed, fields)
	}
	for i := range routed {
		if routed[i] != fields[i] {
			t.Fatalf("routed %v, fields %v", routed, fields)
		}
	}
}

func TestEditorProviderRegistrationBindsEveryRoutedFunction(t *testing.T) {
	service, workspace := openDecodedEditorService(t, &fakeWorkbench{})
	service.Host.mu.Lock()
	service.Host.sessions["a"] = &BackendSession{
		host: service.Host, PluginID: "a", Session: pluginbackend.Session{ID: "session-a"},
		functions: map[string]bool{"keys.lens": true, "keys.tokens": true, "keys.complete": true},
		waiters:   map[string]chan core.BackendEvent{}, done: make(chan struct{}), changed: make(chan struct{}), ready: true,
	}
	service.Host.mu.Unlock()
	selector := `"selector":{"fileExtensions":["properties"]}`
	if _, refusal := respond(t, service, "a", "editor/registerProviders", `{`+contextJSONOf(workspace)+`,"id":"fold",`+selector+`,"providers":{"foldingRange":{"function":"keys.lens"}}}`); refusal == nil || refusal.Code != codeInvalidParams {
		t.Fatalf("unrouted type = %+v", refusal)
	}
	if _, refusal := respond(t, service, "a", "editor/registerProviders", `{`+contextJSONOf(workspace)+`,"id":"gone",`+selector+`,"providers":{"codeLens":{"function":"keys.missing"}}}`); refusal == nil || refusal.Code != CodePreconditionFailed {
		t.Fatalf("unregistered function = %+v", refusal)
	}
	body := `{` + contextJSONOf(workspace) + `,"id":"keys",` + selector + `,"providers":{` +
		`"codeLens":{"function":"keys.lens"},` +
		`"completion":{"function":"keys.complete","triggerCharacters":["."]},` +
		`"semanticTokens":{"function":"keys.tokens","legend":{"tokenTypes":["property"],"tokenModifiers":[]}}}}`
	if _, refusal := respond(t, service, "a", "editor/registerProviders", body); refusal != nil {
		t.Fatalf("register: %+v", refusal)
	}
	service.providers2.mu.Lock()
	defer service.providers2.mu.Unlock()
	if len(service.providers2.list) != 1 {
		t.Fatalf("bindings = %d", len(service.providers2.list))
	}
	binding := service.providers2.list[0]
	if binding.codeLens != "keys.lens" || binding.completion != "keys.complete" || binding.semanticTokens != "keys.tokens" ||
		len(binding.triggers) != 1 || len(binding.tokenTypes) != 1 || binding.definition != "" {
		t.Fatalf("binding = %+v", binding)
	}
}
