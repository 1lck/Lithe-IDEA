package settingswindow

import (
	"testing"
	"unicode/utf8"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/app"
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

// TestGenerationInstructionsSync follows the text of the instructions field through the
// cases the store can show it in: the first paint, a change by someone else, the keystrokes
// whose saves the store has not shown yet, and the store catching up with them.
func TestGenerationInstructionsSync(t *testing.T) {
	var g generationInstructions
	g.sync("a")
	if g.text != "a" || g.waiting {
		t.Fatalf("the first paint must show the stored value, got %+v", g)
	}
	g.sync("b")
	if g.text != "b" {
		t.Fatalf("a change by someone else must replace the text, got %q", g.text)
	}
	g.text = "bc"
	g.send()
	g.sync("b")
	if g.text != "bc" || !g.waiting {
		t.Fatalf("a store that has not shown the save yet must not erase the typing, got %+v", g)
	}
	g.text = "bcd"
	g.send()
	g.sync("bc")
	if g.text != "bcd" || !g.waiting {
		t.Fatalf("the echo of an earlier keystroke must not erase the typing, got %+v", g)
	}
	g.sync("bcd")
	if g.text != "bcd" || g.waiting {
		t.Fatalf("the store showing the last save must end the wait, got %+v", g)
	}
	g.sync("x")
	if g.text != "x" {
		t.Fatalf("a change by someone else after the wait must replace the text, got %q", g.text)
	}
	// Typing the text away and back again leaves the store where it was, which must still
	// end the wait.
	g.text = "xy"
	g.send()
	g.text = "x"
	g.send()
	g.sync("x")
	if g.waiting || g.text != "x" {
		t.Fatalf("a save that matches the store must end the wait, got %+v", g)
	}
}

// generationInstructionsWindow opens Settings > AI with the generation choices read and
// written through the callbacks, tall enough that the whole generation card is on screen.
func generationInstructionsWindow(t *testing.T, read func() AIGenerationSettings, write func(AIGenerationSettings)) *windowDriver {
	t.Helper()
	w := newWindow(NewController(Options{
		AIGeneration:    read,
		SetAIGeneration: write,
	}), Values{})
	w.sess.page = pageAIGeneration
	return openWindow(t, w, func(config *app.Config) { config.Height = 1100 })
}

// appendToInstructions puts the caret at the end of the instructions field and types text.
func appendToInstructions(t *testing.T, d *windowDriver, label, current, text string) {
	t.Helper()
	d.click(label)
	end := utf8.RuneCountInString(current)
	if err := d.driver.SelectText(end, end); err != nil {
		t.Fatal(err)
	}
	d.typeText(text)
}

// repaint paints the window again as a wake from another thread would.
func repaint(d *windowDriver) {
	d.t.Helper()
	d.w.inv.Invalidate()
	d.pump()
}

// TestGenerationInstructionsFieldSavesWhatIsTyped opens the page, checks that reading writes
// nothing, types into the field and checks the saved choices: the new instructions as typed,
// everything else as stored.
func TestGenerationInstructionsFieldSavesWhatIsTyped(t *testing.T) {
	stored := AIGenerationSettings{Provider: "claude", Language: "english", IncludeBody: true, CustomInstructions: "keep it short"}
	var saves []AIGenerationSettings
	d := generationInstructionsWindow(t, func() AIGenerationSettings { return stored }, func(value AIGenerationSettings) {
		saves = append(saves, value)
		stored = value
	})
	label := i18n.Shared(i18n.English, "desktop.commit.instructions")
	d.until("the stored instructions in the field", func() bool { return d.has(label) && d.hit(label).Value == "keep it short" })
	for range 3 {
		repaint(d)
	}
	if len(saves) != 0 {
		t.Fatalf("opening the page saved %+v", saves)
	}

	appendToInstructions(t, d, label, "keep it short", ", no emoji")
	d.until("the typed instructions saved", func() bool { return len(saves) > 0 })
	want := AIGenerationSettings{Provider: "claude", Language: "english", IncludeBody: true, CustomInstructions: "keep it short, no emoji"}
	if len(saves) != 1 || saves[0] != want {
		t.Fatalf("saves = %+v, want one save of %+v", saves, want)
	}
	for range 3 {
		repaint(d)
	}
	if got := d.hit(label).Value; got != want.CustomInstructions {
		t.Fatalf("the field shows %q after the save, want %q", got, want.CustomInstructions)
	}
	if len(saves) != 1 {
		t.Fatalf("repainting saved again: %+v", saves)
	}
}

// TestGenerationInstructionsSurviveTheStoreLagging keeps the owner's store behind the typing,
// as it is until the owner's window drains the save it was handed, and checks that the field keeps
// the typed text, that it takes in a change made elsewhere afterwards, and that none of this
// writes anything beyond the user's own edits.
func TestGenerationInstructionsSurviveTheStoreLagging(t *testing.T) {
	stored := AIGenerationSettings{CustomInstructions: "keep it short"}
	var saves []AIGenerationSettings
	d := generationInstructionsWindow(t, func() AIGenerationSettings { return stored }, func(value AIGenerationSettings) {
		saves = append(saves, value)
	})
	label := i18n.Shared(i18n.English, "desktop.commit.instructions")
	d.until("the stored instructions in the field", func() bool { return d.has(label) && d.hit(label).Value == "keep it short" })

	appendToInstructions(t, d, label, "keep it short", ", no emoji")
	d.until("the first save", func() bool { return len(saves) == 1 })
	for range 3 {
		repaint(d)
	}
	typed := "keep it short, no emoji"
	if got := d.hit(label).Value; got != typed {
		t.Fatalf("a paint that still reads the old store replaced the typing with %q", got)
	}

	appendToInstructions(t, d, label, typed, "!")
	d.until("the second save", func() bool { return len(saves) == 2 })
	if saves[1].CustomInstructions != typed+"!" {
		t.Fatalf("second save = %+v", saves[1])
	}
	stored = saves[0]
	repaint(d)
	stored = saves[1]
	repaint(d)
	if got := d.hit(label).Value; got != typed+"!" {
		t.Fatalf("the store catching up changed the field to %q", got)
	}

	stored.CustomInstructions = "from the commit panel"
	d.until("the change made elsewhere in the field", func() bool { return d.hit(label).Value == "from the commit panel" })
	if len(saves) != 2 {
		t.Fatalf("taking in a change made elsewhere saved %+v", saves[2:])
	}
}
