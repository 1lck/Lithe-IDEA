package workbench

import (
	"reflect"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/settingswindow"
)

func TestAIGenerationSourcesFollowTheChosenProvider(t *testing.T) {
	app := &App{}
	if got := app.aiGenerationSources(); !reflect.DeepEqual(got, []string{"codex", "claude"}) {
		t.Fatalf("automatic sources = %v", got)
	}
	app.settings.AIGeneration = settingswindow.AIGenerationSettings{Provider: "claude"}
	if got := app.aiGenerationSources(); !reflect.DeepEqual(got, []string{"claude"}) {
		t.Fatalf("claude sources = %v", got)
	}
}

func TestPickAIProviderFromRespectsTheSources(t *testing.T) {
	providers := map[string][]aiProvider{
		"codex":  {{Endpoint: "https://a", APIKey: "k"}},
		"claude": {{Endpoint: "https://b", APIKey: "k"}},
	}
	got, ok := pickAIProviderFrom(providers, []string{"claude"})
	if !ok || got.Endpoint != "https://b" {
		t.Fatalf("claude only picked %#v %v", got, ok)
	}
	if _, ok := pickAIProviderFrom(providers, []string{"codex"}); !ok {
		t.Fatal("codex only found nothing")
	}
	if _, ok := pickAIProviderFrom(map[string][]aiProvider{"claude": {{Endpoint: "https://b"}}}, []string{"claude"}); ok {
		t.Fatal("a provider without a key was picked")
	}
}
