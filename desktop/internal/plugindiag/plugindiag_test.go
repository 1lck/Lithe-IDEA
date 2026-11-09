package plugindiag

import (
	"errors"
	"fmt"
	"reflect"
	"sync"
	"testing"
)

// diagnostic builds a storable diagnostic of the named file.
func diagnostic(fileKey string, line, column int, severity Severity, message string) Diagnostic {
	return Diagnostic{
		FileKey:     fileKey,
		DisplayPath: "src/" + fileKey,
		Line:        line,
		Column:      column,
		Severity:    severity,
		Message:     message,
		Source:      "gopls",
		Code:        "typecheck",
	}
}

// mustReplace stores a batch and fails the test when the set refuses it.
func mustReplace(t *testing.T, set *Set, fileKey string, diagnostics ...Diagnostic) {
	t.Helper()
	if err := set.Replace(fileKey, diagnostics); err != nil {
		t.Fatalf("Replace(%q): %v", fileKey, err)
	}
}

func TestSeverityValid(t *testing.T) {
	cases := []struct {
		severity Severity
		valid    bool
	}{
		{SeverityError, true},
		{SeverityWarning, true},
		{SeverityInformation, true},
		{SeverityHint, true},
		{Severity(0), false},
		{Severity(5), false},
		{Severity(-1), false},
	}
	for _, testCase := range cases {
		t.Run(fmt.Sprintf("severity %d", int(testCase.severity)), func(t *testing.T) {
			if got := testCase.severity.Valid(); got != testCase.valid {
				t.Fatalf("Valid() = %t, want %t", got, testCase.valid)
			}
		})
	}
}

func TestDiagnosticValidate(t *testing.T) {
	cases := []struct {
		name       string
		diagnostic Diagnostic
		invalid    bool
	}{
		{"storable", diagnostic("a.go", 0, 0, SeverityError, "undefined: x"), false},
		{
			"optional fields empty",
			Diagnostic{FileKey: "a.go", Line: 2, Column: 3, Severity: SeverityHint, Message: "consider"},
			false,
		},
		{"empty file key", Diagnostic{Line: 0, Column: 0, Severity: SeverityError, Message: "m"}, true},
		{
			"negative line",
			Diagnostic{FileKey: "a.go", Line: -1, Column: 0, Severity: SeverityError, Message: "m"},
			true,
		},
		{
			"negative column",
			Diagnostic{FileKey: "a.go", Line: 0, Column: -1, Severity: SeverityError, Message: "m"},
			true,
		},
		{
			"unknown severity",
			Diagnostic{FileKey: "a.go", Line: 0, Column: 0, Severity: Severity(0), Message: "m"},
			true,
		},
		{
			"empty message",
			Diagnostic{FileKey: "a.go", Line: 0, Column: 0, Severity: SeverityError},
			true,
		},
	}
	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			err := testCase.diagnostic.Validate()
			if testCase.invalid {
				if !errors.Is(err, ErrInvalidDiagnostic) {
					t.Fatalf("Validate() = %v, want ErrInvalidDiagnostic", err)
				}
				return
			}
			if err != nil {
				t.Fatalf("Validate() = %v, want nil", err)
			}
		})
	}
}

func TestReplaceStoresAndSwapsBatch(t *testing.T) {
	set := NewSet()
	first := []Diagnostic{
		diagnostic("a.go", 0, 0, SeverityError, "undefined: x"),
		diagnostic("a.go", 4, 2, SeverityWarning, "declared and not used: y"),
	}
	if err := set.Replace("a.go", first); err != nil {
		t.Fatalf("Replace first batch: %v", err)
	}
	if got := set.All(); !reflect.DeepEqual(got, first) {
		t.Fatalf("All() = %v, want %v", got, first)
	}

	second := []Diagnostic{diagnostic("a.go", 7, 1, SeverityInformation, "shadowed variable")}
	if err := set.Replace("a.go", second); err != nil {
		t.Fatalf("Replace second batch: %v", err)
	}
	if got := set.All(); !reflect.DeepEqual(got, second) {
		t.Fatalf("after the second replace, All() = %v, want %v", got, second)
	}
	if got, want := set.Files(), []string{"a.go"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("Files() = %v, want %v", got, want)
	}
}

func TestReplaceEmptyListClearsFile(t *testing.T) {
	set := NewSet()
	mustReplace(t, set, "a.go", diagnostic("a.go", 0, 0, SeverityError, "undefined: x"))
	mustReplace(t, set, "b.go", diagnostic("b.go", 1, 0, SeverityWarning, "declared and not used: y"))

	cases := []struct {
		name  string
		batch []Diagnostic
	}{
		{"nil", nil},
		{"empty", []Diagnostic{}},
	}
	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			if err := set.Replace("a.go", testCase.batch); err != nil {
				t.Fatalf("Replace with an empty list: %v", err)
			}
			if got, want := set.Files(), []string{"b.go"}; !reflect.DeepEqual(got, want) {
				t.Fatalf("Files() = %v, want %v", got, want)
			}
			if got, want := set.Counts(), map[Severity]int{SeverityWarning: 1}; !reflect.DeepEqual(got, want) {
				t.Fatalf("Counts() = %v, want %v", got, want)
			}
		})
	}
}

func TestClearDropsOneFile(t *testing.T) {
	set := NewSet()
	mustReplace(t, set, "a.go", diagnostic("a.go", 0, 0, SeverityError, "undefined: x"))
	mustReplace(t, set, "b.go", diagnostic("b.go", 0, 0, SeverityHint, "consider"))

	set.Clear("a.go")
	if got, want := set.Files(), []string{"b.go"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("Files() = %v, want %v", got, want)
	}

	set.Clear("never-stored.go")
	if got := set.All(); len(got) != 1 || got[0].FileKey != "b.go" {
		t.Fatalf("All() = %v after clearing a file that holds nothing, want the one diagnostic of b.go", got)
	}
}

func TestClearAllDropsEverything(t *testing.T) {
	set := NewSet()
	mustReplace(t, set, "a.go", diagnostic("a.go", 0, 0, SeverityError, "undefined: x"))
	mustReplace(t, set, "b.go", diagnostic("b.go", 2, 0, SeverityWarning, "declared and not used: y"))

	set.ClearAll()
	if got := set.All(); len(got) != 0 {
		t.Fatalf("All() = %v after ClearAll, want none", got)
	}
	if got := set.Files(); len(got) != 0 {
		t.Fatalf("Files() = %v after ClearAll, want none", got)
	}
	if got := set.Counts(); len(got) != 0 {
		t.Fatalf("Counts() = %v after ClearAll, want none", got)
	}

	mustReplace(t, set, "a.go", diagnostic("a.go", 0, 0, SeverityError, "undefined: x"))
	if got := len(set.All()); got != 1 {
		t.Fatalf("All() has %d diagnostics after storing again, want 1", got)
	}
}

func TestAllOrdersDeterministically(t *testing.T) {
	set := NewSet()
	mustReplace(t, set, "b.go", diagnostic("b.go", 0, 0, SeverityError, "b-first"))
	mustReplace(t, set, "a.go",
		diagnostic("a.go", 2, 0, SeverityWarning, "a-late"),
		diagnostic("a.go", 1, 4, SeverityWarning, "a-early-right"),
		diagnostic("a.go", 1, 1, SeverityHint, "a-early-left"),
		diagnostic("a.go", 3, 0, SeverityWarning, "a-tie-z"),
		diagnostic("a.go", 3, 0, SeverityError, "a-tie-a"),
	)
	want := []string{"a-early-left", "a-early-right", "a-late", "a-tie-a", "a-tie-z", "b-first"}

	for round := 0; round < 5; round++ {
		all := set.All()
		got := make([]string, len(all))
		for i, d := range all {
			got[i] = d.Message
		}
		if !reflect.DeepEqual(got, want) {
			t.Fatalf("round %d: messages = %v, want %v", round, got, want)
		}
	}
}

func TestCountsSkipsAbsentSeverities(t *testing.T) {
	set := NewSet()
	if got := set.Counts(); got == nil || len(got) != 0 {
		t.Fatalf("Counts() of an empty set = %v, want an empty map", got)
	}

	mustReplace(t, set, "a.go",
		diagnostic("a.go", 0, 0, SeverityError, "undefined: x"),
		diagnostic("a.go", 1, 0, SeverityError, "cannot use x as int"),
		diagnostic("a.go", 2, 0, SeverityHint, "consider"),
	)
	mustReplace(t, set, "b.go", diagnostic("b.go", 0, 0, SeverityError, "syntax error"))

	counts := set.Counts()
	want := map[Severity]int{SeverityError: 3, SeverityHint: 1}
	if !reflect.DeepEqual(counts, want) {
		t.Fatalf("Counts() = %v, want %v", counts, want)
	}
	for _, absent := range []Severity{SeverityWarning, SeverityInformation} {
		if count, ok := counts[absent]; ok {
			t.Fatalf("Counts() has severity %d = %d, want the key absent", int(absent), count)
		}
	}

	counts[SeverityError] = 99
	if got := set.Counts()[SeverityError]; got != 3 {
		t.Fatalf("Counts() = %d errors after editing the returned map, want 3", got)
	}
}

func TestFilesSorted(t *testing.T) {
	set := NewSet()
	if got := set.Files(); got == nil || len(got) != 0 {
		t.Fatalf("Files() of an empty set = %v, want an empty slice", got)
	}
	for _, fileKey := range []string{"c.go", "a.go", "b.go"} {
		mustReplace(t, set, fileKey, diagnostic(fileKey, 0, 0, SeverityError, "error in "+fileKey))
	}
	if got, want := set.Files(), []string{"a.go", "b.go", "c.go"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("Files() = %v, want %v", got, want)
	}
}

func TestReplaceRejectsTooManyPerFile(t *testing.T) {
	set := NewSet()
	atLimit := make([]Diagnostic, MaxDiagnosticsPerFile)
	for i := range atLimit {
		atLimit[i] = diagnostic("big.go", i, 0, SeverityError, fmt.Sprintf("error %d", i))
	}
	if err := set.Replace("big.go", atLimit); err != nil {
		t.Fatalf("Replace at the per-file limit: %v", err)
	}

	overLimit := make([]Diagnostic, MaxDiagnosticsPerFile+1)
	for i := range overLimit {
		overLimit[i] = diagnostic("big.go", i, 0, SeverityError, fmt.Sprintf("error %d", i))
	}
	if err := set.Replace("big.go", overLimit); !errors.Is(err, ErrTooMany) {
		t.Fatalf("Replace over the per-file limit = %v, want ErrTooMany", err)
	}
	if got := len(set.All()); got != MaxDiagnosticsPerFile {
		t.Fatalf("All() has %d diagnostics after the rejected replace, want %d", got, MaxDiagnosticsPerFile)
	}
}

func TestReplaceRejectsTooManyFiles(t *testing.T) {
	set := NewSet()
	for i := 0; i < MaxFiles; i++ {
		fileKey := fmt.Sprintf("file-%05d.go", i)
		mustReplace(t, set, fileKey, diagnostic(fileKey, 0, 0, SeverityError, "error"))
	}
	if got := len(set.Files()); got != MaxFiles {
		t.Fatalf("Files() has %d keys, want %d", got, MaxFiles)
	}

	extra := "one-file-too-many.go"
	if err := set.Replace(extra, []Diagnostic{diagnostic(extra, 0, 0, SeverityError, "error")}); !errors.Is(err, ErrTooMany) {
		t.Fatalf("Replace of a new file at the file limit = %v, want ErrTooMany", err)
	}
	if got := len(set.Files()); got != MaxFiles {
		t.Fatalf("Files() has %d keys after the rejected replace, want %d", got, MaxFiles)
	}

	existing := "file-00000.go"
	mustReplace(t, set, existing, diagnostic(existing, 5, 0, SeverityWarning, "still allowed"))
	set.Clear(existing)
	mustReplace(t, set, extra, diagnostic(extra, 0, 0, SeverityError, "error"))
	if got := len(set.Files()); got != MaxFiles {
		t.Fatalf("Files() has %d keys after the freed slot was taken, want %d", got, MaxFiles)
	}
}

func TestReplaceRejectsInvalidBatch(t *testing.T) {
	set := NewSet()
	kept := diagnostic("a.go", 1, 1, SeverityError, "kept")
	mustReplace(t, set, "a.go", kept)

	cases := []struct {
		name       string
		diagnostic Diagnostic
	}{
		{"empty file key", Diagnostic{Line: 0, Column: 0, Severity: SeverityError, Message: "m"}},
		{
			"negative line",
			Diagnostic{FileKey: "a.go", Line: -1, Column: 0, Severity: SeverityError, Message: "m"},
		},
		{
			"negative column",
			Diagnostic{FileKey: "a.go", Line: 0, Column: -1, Severity: SeverityError, Message: "m"},
		},
		{
			"unknown severity",
			Diagnostic{FileKey: "a.go", Line: 0, Column: 0, Severity: Severity(7), Message: "m"},
		},
		{"empty message", Diagnostic{FileKey: "a.go", Line: 0, Column: 0, Severity: SeverityError}},
	}
	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			batch := []Diagnostic{
				diagnostic("a.go", 2, 0, SeverityWarning, "valid"),
				testCase.diagnostic,
			}
			if err := set.Replace("a.go", batch); !errors.Is(err, ErrInvalidDiagnostic) {
				t.Fatalf("Replace with an invalid diagnostic = %v, want ErrInvalidDiagnostic", err)
			}
			if got, want := set.All(), []Diagnostic{kept}; !reflect.DeepEqual(got, want) {
				t.Fatalf("All() = %v after the rejected replace, want %v", got, want)
			}
		})
	}

	if err := set.Replace("", nil); !errors.Is(err, ErrInvalidDiagnostic) {
		t.Fatalf("Replace with an empty file key = %v, want ErrInvalidDiagnostic", err)
	}
	if got, want := set.All(), []Diagnostic{kept}; !reflect.DeepEqual(got, want) {
		t.Fatalf("All() = %v after replacing with an empty file key, want %v", got, want)
	}
}

func TestReplaceCopiesInput(t *testing.T) {
	set := NewSet()
	batch := []Diagnostic{diagnostic("a.go", 0, 0, SeverityError, "original")}
	if err := set.Replace("a.go", batch); err != nil {
		t.Fatalf("Replace: %v", err)
	}

	batch[0].Message = "mutated by the caller"
	batch = append(batch, diagnostic("a.go", 9, 9, SeverityError, "appended by the caller"))

	all := set.All()
	if len(all) != 1 {
		t.Fatalf("All() has %d diagnostics, want 1", len(all))
	}
	if all[0].Message != "original" {
		t.Fatalf("stored message = %q, want %q", all[0].Message, "original")
	}

	all[0].Message = "mutated through All"
	if got := set.All()[0].Message; got != "original" {
		t.Fatalf("stored message = %q after editing the slice All returned, want %q", got, "original")
	}
}

func TestConcurrentUse(t *testing.T) {
	set := NewSet()
	const (
		workers = 8
		rounds  = 50
	)

	var wg sync.WaitGroup
	for worker := 0; worker < workers; worker++ {
		wg.Add(1)
		go func(worker int) {
			defer wg.Done()
			for round := 0; round < rounds; round++ {
				fileKey := fmt.Sprintf("file-%d.go", round%4)
				message := fmt.Sprintf("worker %d round %d", worker, round)
				_ = set.Replace(fileKey, []Diagnostic{diagnostic(fileKey, round, worker, SeverityWarning, message)})
				_ = set.All()
				_ = set.Counts()
				_ = set.Files()
				if round%10 == 0 {
					set.Clear(fileKey)
				}
			}
		}(worker)
	}

	wg.Add(1)
	go func() {
		defer wg.Done()
		for round := 0; round < rounds; round++ {
			set.ClearAll()
		}
	}()

	wg.Wait()
	set.ClearAll()
	if got := set.All(); len(got) != 0 {
		t.Fatalf("All() = %v after ClearAll, want none", got)
	}
	if got := set.Files(); len(got) != 0 {
		t.Fatalf("Files() = %v after ClearAll, want none", got)
	}
}
