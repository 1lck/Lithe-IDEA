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
