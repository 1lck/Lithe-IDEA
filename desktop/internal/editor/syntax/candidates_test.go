package syntax

import (
	"context"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/rope"
	"math/rand/v2"
	"slices"
	"strings"
	"testing"
	"time"
)

func candidateHighlighter(t *testing.T, source string) *Highlighter {
	t.Helper()
	h := newHighlighter(NewRegistry().Syntax("go"), rope.FromString(source), HighlighterOptions{CollectCandidates: true, LineLimit: -1}, false)
	t.Cleanup(h.Close)
	drain(t, h)
	return h
}

func TestCandidatesTimeoutPreservesEarlierSegments(t *testing.T) {
	source := "package main\n" + strings.Repeat("var value = (1)\n", 65)
	h := candidateHighlighter(t, source)
	at := h.text.LineStart(40)
	next := h.text.Insert(at, []byte(" "))
	h.Edit(next, at, at, at+1)
	h.worker.limit = time.Nanosecond
	drain(t, h)
	got, err := h.Candidates(t.Context(), next)
	if err != nil {
		t.Fatal(err)
	}
	if len(got.Brackets) == 0 || len(got.Brackets) >= 130 || !slices.Contains(got.Reasons, "tokenization_timeout") {
		t.Fatalf("timeout discarded trusted prefix or was not reported: brackets=%d reasons=%v", len(got.Brackets), got.Reasons)
	}
}

func TestCandidatesFollowCheckpointInsertionAndRemoval(t *testing.T) {
	rng := rand.New(rand.NewPCG(42, 7))
	h := candidateHighlighter(t, "package main\n"+strings.Repeat("var value = (1)\n", 100))
	for range 80 {
		at := rng.IntN(h.text.Len())
		end := min(h.text.Len(), at+rng.IntN(40))
		insert := []byte([]string{"\n", "/*\ncomment\n*/", "(value)", "", ".\nfield"}[rng.IntN(5)])
		next := h.text.Delete(at, end).Insert(at, insert)
		h.Edit(next, at, end, at+len(insert))
		drain(t, h)
		got, err := h.Candidates(t.Context(), next)
		if err != nil {
			t.Fatal(err)
		}
		brackets, variables := RainbowCandidates(t.Context(), next, h.Syntax(), true, true)
		if !slices.Equal(got.Brackets, brackets) || !slices.Equal(got.Variables, variables) {
			t.Fatalf("incremental result differs after edit at %d..%d inserting %q", at, end, insert)
		}
	}
}

func TestCandidatesDeletionRechecksSurvivingSegmentInput(t *testing.T) {
	source := "package main\n" + strings.Repeat("\n", 31) + "object.\n" + strings.Repeat("\n", 63) + "field\n"
	h := candidateHighlighter(t, source)
	from, through := h.text.LineStart(31), h.text.LineStart(65)
	next := h.text.Delete(from, through)
	h.Edit(next, from, through, from)
	drain(t, h)
	got, err := h.Candidates(t.Context(), next)
	if err != nil {
		t.Fatal(err)
	}
	_, want := RainbowCandidates(t.Context(), next, h.Syntax(), true, true)
	if !slices.Equal(got.Variables, want) {
		t.Fatalf("surviving segment kept obsolete accessor state: got=%v want=%v", got.Variables, want)
	}
}

func TestCandidatesReuseCleanSegmentsAfterNeutralEdit(t *testing.T) {
	source := "package main\n" + strings.Repeat("var value = (1)\n", 96)
	h := candidateHighlighter(t, source)
	last := h.candidates.parts[len(h.candidates.parts)-1].brackets
	at := strings.Index(source, "1")
	next := h.text.Delete(at, at+1).Insert(at, []byte("2"))
	h.Edit(next, at, at+1, at+1)
	steps := 1
	for h.step() {
		steps++
		if steps > 1000 {
			t.Fatal("worker did not converge")
		}
	}
	if steps != 1 {
		t.Fatalf("neutral edit retokenized %d segments, want 1", steps)
	}
	reused := h.candidates.parts[len(h.candidates.parts)-1].brackets
	if &last[0] != &reused[0] {
		t.Fatal("unaffected segment candidates were rebuilt")
	}
	got, err := h.Candidates(t.Context(), next)
	if err != nil {
		t.Fatal(err)
	}
	brackets, variables := RainbowCandidates(t.Context(), next, h.Syntax(), true, true)
	if !slices.Equal(got.Brackets, brackets) || !slices.Equal(got.Variables, variables) {
		t.Fatal("incremental candidates differ from a fresh pass")
	}
}

func TestCandidatesConvergeCrossSegmentAccessorState(t *testing.T) {
	source := "package main\n" + strings.Repeat("\n", 30) + "object.\nfield\n"
	h := candidateHighlighter(t, source)
	before, err := h.Candidates(t.Context(), h.text)
	if err != nil {
		t.Fatal(err)
	}
	at := strings.Index(source, ".")
	next := h.text.Delete(at, at+1).Insert(at, []byte("+"))
	h.Edit(next, at, at+1, at+1)
	drain(t, h)
	after, err := h.Candidates(t.Context(), next)
	if err != nil {
		t.Fatal(err)
	}
	if slices.Equal(before.Variables, after.Variables) {
		t.Fatal("cross-segment candidate state did not propagate")
	}
	brackets, variables := RainbowCandidates(t.Context(), next, h.Syntax(), true, true)
	if !slices.Equal(after.Brackets, brackets) || !slices.Equal(after.Variables, variables) {
		t.Fatal("candidate convergence differs from sequential tokenization")
	}
}

func TestCandidatesKeepPrefixAndReportDegradation(t *testing.T) {
	for _, tc := range []struct {
		name, source, reason string
		count                int
	}{
		{"long line", "package main\nfunc main() {}\n" + strings.Repeat(" ", maxLineBytes+1) + "\n()", "line_too_long", 4},
		{"brackets", "package main\n" + strings.Repeat("var value = (1)\n", rainbowBracketMaxCount/2+1), "bracket_limit", rainbowBracketMaxCount},
	} {
		t.Run(tc.name, func(t *testing.T) {
			h := candidateHighlighter(t, tc.source)
			got, err := h.Candidates(t.Context(), h.text)
			if err != nil {
				t.Fatal(err)
			}
			if len(got.Brackets) != tc.count || !slices.Contains(got.Reasons, tc.reason) {
				t.Fatalf("prefix=%d reasons=%v", len(got.Brackets), got.Reasons)
			}
		})
	}
}

func TestCandidatesRejectStaleAndClosedSnapshot(t *testing.T) {
	h := candidateHighlighter(t, "package main\nvar value = (1)\n")
	old := h.text
	next := old.Insert(0, []byte(" "))
	h.Edit(next, 0, 0, 1)
	if _, err := h.Candidates(context.Background(), old); err != context.Canceled {
		t.Fatalf("stale snapshot error=%v", err)
	}
	h.Close()
	if _, err := h.Candidates(context.Background(), next); err != context.Canceled {
		t.Fatalf("closed dirty snapshot error=%v", err)
	}
}

func TestCandidatesBoundStorageAndRefillAfterDeletion(t *testing.T) {
	source := "package main\n" + strings.Repeat("var value = "+strings.Repeat("(value)+", 100)+"0\n", 101)
	h := candidateHighlighter(t, source)
	check := func() {
		t.Helper()
		brackets, variables := 0, 0
		for _, part := range h.candidates.parts {
			brackets += len(part.brackets)
			variables += len(part.variables)
		}
		if brackets > rainbowBracketMaxCount || variables > rainbowVariableMaxCount {
			t.Fatalf("retained brackets=%d variables=%d exceed document caps", brackets, variables)
		}
		got, err := h.Candidates(t.Context(), h.text)
		if err != nil {
			t.Fatal(err)
		}
		wantBrackets, wantVariables := RainbowCandidates(t.Context(), h.text, h.Syntax(), true, true)
		if !slices.Equal(got.Brackets, wantBrackets) || !slices.Equal(got.Variables, wantVariables) {
			t.Fatal("bounded incremental prefix differs from a fresh pass")
		}
	}
	check()
	end := h.text.LineStart(70)
	next := h.text.Delete(0, end)
	h.Edit(next, 0, end, 0)
	drain(t, h)
	check()
}
