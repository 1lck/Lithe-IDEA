package settingswindow

import (
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
)

func TestGenerationChoicesRoundTrip(t *testing.T) {
	for i, value := range generationProviderChoices {
		if got := generationIndex(generationProviderChoices[:], value); got != i {
			t.Fatalf("provider %q index %d, want %d", value, got, i)
		}
	}
	for i, value := range generationLanguageChoices {
		if got := generationIndex(generationLanguageChoices[:], value); got != i {
			t.Fatalf("language %q index %d, want %d", value, got, i)
		}
	}
	if got := generationIndex(generationProviderChoices[:], "unknown"); got != 0 {
		t.Fatalf("unknown provider index %d, want the automatic choice", got)
	}
}

func TestGenerationSourceLineNeverShowsAKey(t *testing.T) {
	line := (&window{}).generationSourceLine(i18n.English, "codex", []AIProviderStatus{{Source: "codex", Name: "Relay", Model: "m", Path: "/x/config.toml", Usable: true}}, true)
	if line == "" || containsSecretMarker(line) {
		t.Fatalf("line = %q", line)
	}
	if got := (&window{}).generationSourceLine(i18n.English, "claude", nil, false); got == "" {
		t.Fatal("loading line is empty")
	}
}

func containsSecretMarker(s string) bool {
	for _, marker := range []string{"sk-", "Bearer"} {
		for i := 0; i+len(marker) <= len(s); i++ {
			if s[i:i+len(marker)] == marker {
				return true
			}
		}
	}
	return false
}
