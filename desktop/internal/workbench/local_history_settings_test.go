package workbench

import (
	"context"
	"errors"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/settingswindow"
)

// TestLocalHistorySettingsReachCore: the stored rules keep the files they match out of what is
// recorded, and the settings window's source has Core say which rule leaves a path out, with
// the line of the rule as typed, refuse a path outside the project, measure the project's
// history under the limit Core keeps and clear it.
func TestLocalHistorySettingsReachCore(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	root := t.TempDir()
	h.open(root)
	p := h.app.project
	h.app.settings.LocalHistory = settingswindow.LocalHistorySettings{
		IgnorePatterns: []string{"**/generated/"},
		IgnoreRegexes:  []string{`\.tmp$`},
		LimitMegabytes: 5,
	}
	for _, name := range []string{"generated/a.txt", "b.tmp", "src/c.txt"} {
		h.app.recordLocalHistory(p, filepath.Join(root, filepath.FromSlash(name)), "save", historyTexts{before: []byte("one\n"), after: []byte("two\n")})
	}
	h.settle()

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	kernel := h.app.kernel.(localHistoryKernel)
	storage, _ := h.app.localHistoryDirectory(root)
	for name, recorded := range map[string]bool{"generated/a.txt": false, "b.tmp": false, "src/c.txt": true} {
		entries, err := kernel.HistoryEntries(ctx, root, storage, name)
		if err != nil {
			t.Fatal(err)
		}
		if (len(entries) > 0) != recorded {
			t.Fatalf("%s has %d snapshots, want recorded %v", name, len(entries), recorded)
		}
	}

	source := h.app.localHistorySettingsSource()
	if source == nil {
		t.Fatal("the real kernel gives the settings window no local history")
	}
	rules := core.HistoryIgnoreRules{PathPatterns: []string{"**/generated/"}, PathRegexes: []string{"", "(", `\.tmp$`}}
	preview, err := source.Preview(ctx, rules, "generated/a.txt")
	if err != nil {
		t.Fatal(err)
	}
	if m := preview.Matched; m == nil || m.Kind != "pattern" || m.Pattern != "**/generated/" {
		t.Fatalf("generated/a.txt matched %+v, want the wildcard rule", m)
	}
	if len(preview.RegexErrors) != 1 || preview.RegexErrors[0].Index != 1 || preview.RegexErrors[0].Message == "" {
		t.Fatalf("regex errors %+v, want the second line", preview.RegexErrors)
	}
	if len(preview.BuiltInIgnorePatterns) == 0 {
		t.Fatal("Core named no built-in rules")
	}
	if preview, err = source.Preview(ctx, rules, "x.tmp"); err != nil || preview.Matched == nil || preview.Matched.Kind != "regex" || preview.Matched.Index != 2 {
		t.Fatalf("x.tmp matched %+v, %v, want the third regular expression line", preview.Matched, err)
	}
	// Some built-in folders are hidden in the project tree too, which Core reports first; any
	// other one is reported as the built-in rule that keeps it out.
	builtIn := false
	for _, pattern := range preview.BuiltInIgnorePatterns {
		name, ok := strings.CutPrefix(pattern, "**/")
		if !ok || !strings.HasSuffix(name, "/") {
			continue
		}
		folder, err := source.Preview(ctx, core.HistoryIgnoreRules{}, name+"x.txt")
		if err != nil || folder.Matched == nil {
			t.Fatalf("%sx.txt matched %+v, %v, want it kept out", name, folder.Matched, err)
		}
		if folder.Matched.Kind == "pattern" && folder.Matched.Pattern == pattern {
			builtIn = true
		}
	}
	if !builtIn {
		t.Fatalf("no built-in folder of %q is reported as its built-in rule", preview.BuiltInIgnorePatterns)
	}
	var refused *core.Error
	if _, err = source.Preview(ctx, rules, "../outside.txt"); !errors.As(err, &refused) || refused.Code != core.CodeInvalidRequest {
		t.Fatalf("a path outside the project gave %v, want an invalid request", err)
	}

	usage, open, err := source.Usage(ctx, 5)
	if err != nil || !open {
		t.Fatalf("usage = %+v, open %v, %v", usage, open, err)
	}
	if usage.UsedBytes == 0 || usage.LimitBytes != 10<<20 {
		t.Fatalf("usage = %+v, want the recorded file under Core's smallest limit of 10 MiB", usage)
	}
	if err := source.Clear(ctx); err != nil {
		t.Fatal(err)
	}
	if usage, _, err = source.Usage(ctx, 0); err != nil || usage.UsedBytes != 0 || usage.LimitBytes != 100<<20 {
		t.Fatalf("after clearing, usage = %+v, %v, want nothing used under the default 100 MiB", usage, err)
	}
	if entries, err := kernel.HistoryEntries(ctx, root, storage, "src/c.txt"); err != nil || len(entries) != 0 {
		t.Fatalf("after clearing, src/c.txt has %d snapshots, %v", len(entries), err)
	}

	h.app.closeProject()
	h.settle()
	if _, open, err := source.Usage(ctx, 0); err != nil || open {
		t.Fatalf("without a project usage is open %v, %v", open, err)
	}
}
