package settingswindow

import (
	"context"
	"errors"
	"slices"
	"strings"
	"sync"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/app"
)

// fakeLocalHistory answers the card the way Core would for a small set of rules: "**/gen/"
// keeps a generated folder out, a line "(" is not a regular expression, and a path starting
// with ".." is outside the project.
type fakeLocalHistory struct {
	mu       sync.Mutex
	previews []core.HistoryIgnoreRules
	paths    []string
	limits   []int
	usage    core.HistoryUsage
	open     bool
	clears   int
	clearErr error
}

var fakeBuiltIns = []string{"**/node_modules/", "**/target/"}

func (f *fakeLocalHistory) Preview(_ context.Context, rules core.HistoryIgnoreRules, path string) (core.HistoryIgnorePreview, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.previews, f.paths = append(f.previews, rules), append(f.paths, path)
	if strings.HasPrefix(path, "..") {
		return core.HistoryIgnorePreview{}, &core.Error{Code: core.CodeInvalidRequest, Message: "Path must be relative"}
	}
	out := core.HistoryIgnorePreview{BuiltInIgnorePatterns: fakeBuiltIns}
	for i, line := range rules.PathRegexes {
		if line == "(" {
			out.RegexErrors = append(out.RegexErrors, core.HistoryRegexError{Index: i, Message: "unclosed group"})
		}
	}
	if path == "" {
		return out, nil
	}
	ignored := false
	out.GitIgnored = &ignored
	if strings.HasPrefix(path, "src/gen/") && slices.Contains(rules.PathPatterns, "**/gen/") {
		out.Matched = &core.HistoryIgnoreMatch{Kind: "pattern", Pattern: "**/gen/"}
	}
	return out, nil
}

func (f *fakeLocalHistory) Usage(_ context.Context, limit int) (core.HistoryUsage, bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.limits = append(f.limits, limit)
	return f.usage, f.open, nil
}

func (f *fakeLocalHistory) Clear(context.Context) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.clears++
	if f.clearErr == nil {
		f.usage.UsedBytes = 0
	}
	return f.clearErr
}

// lastPreview is the rules and the path of the latest preview.
func (f *fakeLocalHistory) lastPreview() (core.HistoryIgnoreRules, string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if len(f.previews) == 0 {
		return core.HistoryIgnoreRules{}, ""
	}
	return f.previews[len(f.previews)-1], f.paths[len(f.paths)-1]
}

// openLocalHistoryCard shows the General page, tall enough for the local history card, with
// stored as the stored settings.
func openLocalHistoryCard(t *testing.T, source *fakeLocalHistory, stored LocalHistorySettings, applied func(LocalHistorySettings)) (*window, *windowDriver) {
	t.Helper()
	if applied == nil {
		applied = func(LocalHistorySettings) {}
	}
	w := newWindow(NewController(Options{SetLocalHistory: applied, LocalHistory: source}), Values{LocalHistory: stored})
	w.sess.page = pageGeneral
	return w, openWindow(t, w, func(config *app.Config) { config.Height = 2400 })
}

// TestLocalHistoryCardChecksTheRulesAsTheyAreTyped: the card shows the project's history size
// against Core's limit and Core's built-in rules, sends the rules line for line as typed, names
// the line of a regular expression Core cannot read, and says for the test path which rule
// keeps it out, whether Git ignores it, or that it is outside the project.
func TestLocalHistoryCardChecksTheRulesAsTheyAreTyped(t *testing.T) {
	source := &fakeLocalHistory{usage: core.HistoryUsage{UsedBytes: 7 << 19, LimitBytes: 100 << 20}, open: true}
	w, d := openLocalHistoryCard(t, source, LocalHistorySettings{IgnorePatterns: []string{"*.log"}}, nil)
	text := func(id string) string { return i18n.Shared(i18n.English, id) }
	format := func(id, key, value string) string {
		return i18n.SharedFormat(i18n.English, id, map[string]string{key: value})
	}

	d.until("the project's history size", func() bool { return d.text("3.5 MB / 100 MB") })
	builtIns := format("desktop.settings.localHistory.builtIns", "patterns", strings.Join(fakeBuiltIns, "  "))
	d.until("Core's built-in rules", func() bool { return d.showsHelp(builtIns) })
	if rules, path := source.lastPreview(); !slices.Equal(rules.PathPatterns, []string{"*.log"}) || path != "" {
		t.Fatalf("the first preview sent %+v for %q, want the stored rule", rules, path)
	}

	w.localHistory.patterns.SetText("*.log\n**/gen/")
	w.localHistory.regexes.SetText("^build/\n(")
	w.localHistory.path.SetText("src/gen/api.txt")
	verdict := format("native.localHistoryFormat", "arg1", format("native.ignoredByWildcardRule", "arg1", "**/gen/"))
	d.until("the wildcard rule that keeps the path out", func() bool { return d.text(verdict) && d.text(text("native.gitNotIgnored")) })
	if rules, _ := source.lastPreview(); !slices.Equal(rules.PathRegexes, []string{"^build/", "("}) {
		t.Fatalf("the preview sent the regular expressions %q, want the lines as typed", rules.PathRegexes)
	}
	failure := format("native.lineLldIsNotAValidRegularExpressionAndIsSkipped", "arg1", "2") + " unclosed group"
	d.until("the line Core cannot read", func() bool { return d.showsHelp(failure) })

	w.localHistory.path.SetText("src/main.go")
	recorded := format("native.localHistoryFormat", "arg1", text("native.recorded"))
	d.until("a recorded path", func() bool { return d.text(recorded) })

	w.localHistory.path.SetText("../outside.txt")
	d.until("a path outside the project", func() bool { return d.text(text("native.aTestPathMustStayInsideTheCurrent")) })
	if !d.showsHelp(builtIns) {
		t.Fatal("a refused path took Core's built-in rules off the card")
	}
}

// TestLocalHistoryCardAppliesTrimmedRulesAndTheLimit: Apply refuses a limit that is not a whole
// number of megabytes, stores each rule trimmed without blank lines, measures again under the
// new limit, and Revert brings the stored rules back.
func TestLocalHistoryCardAppliesTrimmedRulesAndTheLimit(t *testing.T) {
	source := &fakeLocalHistory{usage: core.HistoryUsage{UsedBytes: 1 << 20, LimitBytes: 100 << 20}, open: true}
	var applied []LocalHistorySettings
	w, d := openLocalHistoryCard(t, source, LocalHistorySettings{}, func(next LocalHistorySettings) { applied = append(applied, next) })
	text := func(id string) string { return i18n.Shared(i18n.English, id) }
	d.until("the project's history size", func() bool { return d.text("1 MB / 100 MB") })

	w.localHistory.patterns.SetText("  *.log \n\n**/gen/\n")
	w.localHistory.regexes.SetText("\n^build/ ")
	w.localHistory.limit.SetText("2.5")
	d.click(text("desktop.settings.network.apply"))
	d.pump()
	if len(applied) != 0 || !d.showsHelp(text("desktop.settings.localHistory.invalidLimit")) {
		t.Fatalf("a limit of 2.5 MB: applied %+v, refusal shown %v", applied, d.showsHelp(text("desktop.settings.localHistory.invalidLimit")))
	}

	w.localHistory.limit.SetText(" 250 ")
	d.click(text("desktop.settings.network.apply"))
	d.pump()
	want := LocalHistorySettings{IgnorePatterns: []string{"*.log", "**/gen/"}, IgnoreRegexes: []string{"^build/"}, LimitMegabytes: 250}
	if len(applied) != 1 || !slices.Equal(applied[0].IgnorePatterns, want.IgnorePatterns) || !slices.Equal(applied[0].IgnoreRegexes, want.IgnoreRegexes) || applied[0].LimitMegabytes != 250 {
		t.Fatalf("applied %+v, want %+v", applied, want)
	}
	if d.showsHelp(text("desktop.settings.localHistory.invalidLimit")) {
		t.Fatal("the refusal stayed after a valid apply")
	}
	d.until("a measure under the new limit", func() bool {
		source.mu.Lock()
		defer source.mu.Unlock()
		return slices.Contains(source.limits, 250)
	})
	if got := w.localHistory.patterns.Text(); got != "*.log\n**/gen/" {
		t.Fatalf("the applied rules read %q, want them as stored", got)
	}

	w.localHistory.patterns.SetText("other/")
	w.localHistory.limit.SetText("")
	d.click(text("desktop.settings.network.revert"))
	d.pump()
	if w.localHistory.patterns.Text() != "*.log\n**/gen/" || w.localHistory.limit.Text() != "250" || len(applied) != 1 {
		t.Fatalf("Revert left %q and %q, applied %d", w.localHistory.patterns.Text(), w.localHistory.limit.Text(), len(applied))
	}
}

// TestLocalHistoryCardClearsAfterAsking: Clear asks first and Cancel keeps the history; the
// answer clears it and the card measures it again; a failed clear says so and Retry asks again.
// Without a project the card says to open one.
func TestLocalHistoryCardClearsAfterAsking(t *testing.T) {
	source := &fakeLocalHistory{usage: core.HistoryUsage{UsedBytes: 2 << 20, LimitBytes: 100 << 20}, open: true}
	w, d := openLocalHistoryCard(t, source, LocalHistorySettings{}, nil)
	text := func(id string) string { return i18n.Shared(i18n.English, id) }
	clears := func() int {
		source.mu.Lock()
		defer source.mu.Unlock()
		return source.clears
	}
	d.until("the project's history size", func() bool { return d.text("2 MB / 100 MB") })

	d.click(text("native.clearProjectHistory"))
	d.pump()
	if !d.text(text("native.clearThisProjectSLocalHistory")) {
		t.Fatal("Clear did not ask first")
	}
	d.click(text("desktop.pluginSettings.actionCancel"))
	d.pump()
	if clears() != 0 || d.text(text("native.clearThisProjectSLocalHistory")) {
		t.Fatalf("Cancel cleared %d times or left the question up", clears())
	}

	source.mu.Lock()
	source.clearErr = errors.New("permission denied")
	source.mu.Unlock()
	d.click(text("native.clearProjectHistory"))
	d.pump()
	d.click(text("ui.clear"))
	d.until("the failed clear", func() bool { return d.showsHelp(text("history.clearFailed")) })
	if clears() != 1 || !d.text("2 MB / 100 MB") {
		t.Fatalf("a failed clear: %d clears, size shown %v", clears(), d.text("2 MB / 100 MB"))
	}

	source.mu.Lock()
	source.clearErr = nil
	source.mu.Unlock()
	d.click(text("ui.retry"))
	d.pump()
	d.click(text("ui.clear"))
	d.until("the cleared history", func() bool { return d.text("0 KB / 100 MB") })
	if clears() != 2 || d.showsHelp(text("history.clearFailed")) {
		t.Fatalf("Retry: %d clears, failure still shown %v", clears(), d.showsHelp(text("history.clearFailed")))
	}
	if hit, ok := d.find(text("native.clearProjectHistory")); !ok || !hit.Disabled {
		t.Fatalf("an empty history can still be cleared: %+v", hit)
	}

	source.mu.Lock()
	source.open = false
	source.mu.Unlock()
	w.measureLocalHistory()
	d.until("the card without a project", func() bool {
		return d.showsHelp(text("native.openAProjectToSeeHowMuchSpaceItsHistoryUses"))
	})
}
