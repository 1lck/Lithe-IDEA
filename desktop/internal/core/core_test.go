package core

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"
)

// testDeadline bounds every wait in these tests, so a stuck kernel call fails the test with a
// diagnostic instead of waiting for the test binary's global timeout.
const testDeadline = 30 * time.Second

// testContext returns a context that ends after testDeadline and is released with the test.
func testContext(t *testing.T) context.Context {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), testDeadline)
	t.Cleanup(cancel)
	return ctx
}

// finishesWithin runs fn and fails the test when it has not returned after limit. limit only
// bounds the wait; no test result depends on how long fn takes.
func finishesWithin(t *testing.T, name string, limit time.Duration, fn func()) {
	t.Helper()
	finished := make(chan struct{})
	go func() {
		defer close(finished)
		fn()
	}()
	timer := time.NewTimer(limit)
	defer timer.Stop()
	select {
	case <-finished:
	case <-timer.C:
		t.Fatalf("%s did not finish within %s", name, limit)
	}
}

// requireCode fails unless err is a *Error with the wanted code, and returns it.
func requireCode(t *testing.T, err error, want ErrorCode) *Error {
	t.Helper()
	var coreErr *Error
	if !errors.As(err, &coreErr) {
		t.Fatalf("error = %v (%T), want *Error with code %q", err, err, want)
	}
	if coreErr.Code != want {
		t.Fatalf("error code = %q, want %q (error: %v)", coreErr.Code, want, coreErr)
	}
	return coreErr
}

// writeFile creates path, and any missing parent directory, with content.
func writeFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("create directory for %s: %v", path, err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
}

func TestVersion(t *testing.T) {
	if version := NewClient().Version(); version == "" {
		t.Fatal("Version() is empty")
	}
}

func TestErrorString(t *testing.T) {
	err := &Error{Command: "git.status", Code: CodeProcessFailed, Message: "Git status failed", Details: "boom"}
	want := "lithe core: git.status: Git status failed (process_failed)"
	if got := err.Error(); got != want {
		t.Fatalf("Error() = %q, want %q", got, want)
	}
}

func TestErrorMatchesContextErrors(t *testing.T) {
	tests := []struct {
		code         ErrorCode
		wantCanceled bool
		wantDeadline bool
	}{
		{CodeCancelled, true, false},
		{CodeTimedOut, false, true},
		{CodeProcessFailed, false, false},
		{CodeUnknown, false, false},
	}
	for _, tt := range tests {
		var err error = &Error{Command: "x", Code: tt.code, Message: "m"}
		if got := errors.Is(err, context.Canceled); got != tt.wantCanceled {
			t.Errorf("code %q: errors.Is(Canceled) = %v, want %v", tt.code, got, tt.wantCanceled)
		}
		if got := errors.Is(err, context.DeadlineExceeded); got != tt.wantDeadline {
			t.Errorf("code %q: errors.Is(DeadlineExceeded) = %v, want %v", tt.code, got, tt.wantDeadline)
		}
	}
}

func TestExecuteUnknownCommand(t *testing.T) {
	client := NewClient()
	// The kernel answers a command name it does not know with not_supported, not
	// invalid_request.
	err := client.Execute(testContext(t), "no.such.command", nil, nil)
	coreErr := requireCode(t, err, CodeNotSupported)
	if coreErr.Command != "no.such.command" {
		t.Errorf("Command = %q, want %q", coreErr.Command, "no.such.command")
	}
	if coreErr.Details != "no.such.command" {
		t.Errorf("Details = %q, want the command name", coreErr.Details)
	}
	if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
		t.Errorf("a not_supported error must not match a context error: %v", err)
	}
}

func TestExecuteDoneContextDoesNotCallKernel(t *testing.T) {
	cancelled, cancel := context.WithCancel(context.Background())
	cancel()
	// A deadline in the past is done immediately and needs no waiting.
	expired, release := context.WithDeadline(context.Background(), time.Unix(1, 0))
	defer release()

	tests := []struct {
		name string
		ctx  context.Context
		want error
	}{
		{"cancelled", cancelled, context.Canceled},
		{"deadline passed", expired, context.DeadlineExceeded},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			client := NewClient()
			err := client.Execute(tt.ctx, "workspace.visibilityDefaults", nil, nil)
			if !errors.Is(err, tt.want) {
				t.Fatalf("Execute() = %v, want %v", err, tt.want)
			}
			var coreErr *Error
			if errors.As(err, &coreErr) {
				t.Fatalf("Execute() = %v, want the bare context error", err)
			}
			if used := client.nextOperation.Load(); used != 0 {
				t.Fatalf("Execute() numbered %d operations, want 0: the kernel must not be called", used)
			}
		})
	}
}

func TestExecuteEncodingFailureIsInvalidRequest(t *testing.T) {
	client := NewClient()
	// A channel cannot be encoded as JSON.
	err := client.Execute(testContext(t), "workspace.visibilityDefaults", make(chan int), nil)
	requireCode(t, err, CodeInvalidRequest)
}

func TestCancelOperationUnknownIDFindsNothing(t *testing.T) {
	if cancelOperation("desktop-never-started") {
		t.Fatal("cancelOperation() = true for an operation that is not running")
	}
}

func TestWatchCancellationStops(t *testing.T) {
	t.Run("context cancelled", func(t *testing.T) {
		ctx, cancel := context.WithCancel(context.Background())
		stop := watchCancellation(ctx, "desktop-test-cancelled")
		cancel()
		finishesWithin(t, "stop after cancellation", testDeadline, stop)
	})
	t.Run("context still live", func(t *testing.T) {
		ctx, cancel := context.WithCancel(context.Background())
		defer cancel()
		stop := watchCancellation(ctx, "desktop-test-live")
		finishesWithin(t, "stop of a live watcher", testDeadline, stop)
	})
	t.Run("context that can never be done", func(t *testing.T) {
		stop := watchCancellation(context.Background(), "desktop-test-background")
		finishesWithin(t, "stop without a watcher", testDeadline, stop)
	})
}

func TestDecodeResponse(t *testing.T) {
	type data struct {
		Value int `json:"value"`
	}
	tests := []struct {
		name     string
		response string
		useData  bool
		wantCode ErrorCode // empty means the call succeeds
		wantData int
	}{
		{name: "no response", response: "", useData: true, wantCode: CodeParseFailed},
		{name: "not json", response: "not json", useData: true, wantCode: CodeParseFailed},
		{name: "failure without error", response: `{"ok":false}`, useData: true, wantCode: CodeParseFailed},
		{name: "success without data", response: `{"ok":true}`, useData: true, wantCode: CodeParseFailed},
		{name: "data of the wrong shape", response: `{"ok":true,"data":{"value":"x"}}`, useData: true, wantCode: CodeParseFailed},
		{name: "data decoded", response: `{"ok":true,"data":{"value":7}}`, useData: true, wantData: 7},
		{name: "data not wanted", response: `{"ok":true}`, useData: false},
		{name: "kernel failure", response: `{"ok":false,"error":{"code":"workspace_not_found","message":"gone","details":"/x"}}`, useData: true, wantCode: CodeWorkspaceNotFound},
		{name: "code from a newer kernel", response: `{"ok":false,"error":{"code":"brand_new","message":"m"}}`, useData: true, wantCode: "brand_new"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var result data
			var target any
			if tt.useData {
				target = &result
			}
			err := decodeResponse(context.Background(), "test.command", []byte(tt.response), target)
			if tt.wantCode == "" {
				if err != nil {
					t.Fatalf("decodeResponse() = %v, want success", err)
				}
				if result.Value != tt.wantData {
					t.Fatalf("decoded value = %d, want %d", result.Value, tt.wantData)
				}
				return
			}
			coreErr := requireCode(t, err, tt.wantCode)
			if coreErr.Command != "test.command" {
				t.Errorf("Command = %q, want %q", coreErr.Command, "test.command")
			}
		})
	}

	t.Run("kernel failure keeps message and details", func(t *testing.T) {
		response := `{"ok":false,"error":{"code":"workspace_not_found","message":"gone","details":"/x"}}`
		err := decodeResponse(context.Background(), "test.command", []byte(response), nil)
		coreErr := requireCode(t, err, CodeWorkspaceNotFound)
		if coreErr.Message != "gone" || coreErr.Details != "/x" {
			t.Fatalf("Message, Details = %q, %q, want %q, %q", coreErr.Message, coreErr.Details, "gone", "/x")
		}
	})
}

func TestDecodeResponseKernelCancellation(t *testing.T) {
	cancelledResponse := []byte(`{"ok":false,"error":{"code":"cancelled","message":"Operation cancelled"}}`)
	timedOutResponse := []byte(`{"ok":false,"error":{"code":"timed_out","message":"Operation timed out"}}`)

	t.Run("live context keeps the kernel error", func(t *testing.T) {
		err := decodeResponse(context.Background(), "x", cancelledResponse, nil)
		requireCode(t, err, CodeCancelled)
		if !errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
			t.Fatalf("a cancelled error must match only context.Canceled: %v", err)
		}
		err = decodeResponse(context.Background(), "x", timedOutResponse, nil)
		requireCode(t, err, CodeTimedOut)
		if !errors.Is(err, context.DeadlineExceeded) || errors.Is(err, context.Canceled) {
			t.Fatalf("a timed_out error must match only context.DeadlineExceeded: %v", err)
		}
	})

	t.Run("cancelled context reports its own error", func(t *testing.T) {
		ctx, cancel := context.WithCancel(context.Background())
		cancel()
		err := decodeResponse(ctx, "x", cancelledResponse, nil)
		if err != context.Canceled {
			t.Fatalf("decodeResponse() = %v, want context.Canceled itself", err)
		}
	})

	t.Run("expired deadline reports its own error", func(t *testing.T) {
		ctx, cancel := context.WithDeadline(context.Background(), time.Unix(1, 0))
		defer cancel()
		err := decodeResponse(ctx, "x", cancelledResponse, nil)
		if err != context.DeadlineExceeded {
			t.Fatalf("decodeResponse() = %v, want context.DeadlineExceeded itself", err)
		}
	})

	t.Run("other failures stay kernel errors", func(t *testing.T) {
		ctx, cancel := context.WithCancel(context.Background())
		cancel()
		response := []byte(`{"ok":false,"error":{"code":"process_failed","message":"m"}}`)
		requireCode(t, decodeResponse(ctx, "x", response, nil), CodeProcessFailed)
	})
}

func TestClientIsSafeForConcurrentUse(t *testing.T) {
	const callers = 8
	client := NewClient()
	// The cancel makes ctx.Done() non-nil, so every call also runs its cancellation watcher.
	ctx, cancel := context.WithCancel(testContext(t))
	defer cancel()

	results := make(chan error, callers)
	finishesWithin(t, "concurrent kernel calls", testDeadline, func() {
		var wg sync.WaitGroup
		for range callers {
			wg.Add(1)
			go func() {
				defer wg.Done()
				action := RecordRecent("/projects/concurrent", time.UnixMilli(1_700_000_000_000))
				result, err := client.ReduceRecentProjects(ctx, nil, action, 0)
				if err == nil && len(result.Entries) != 1 {
					err = errors.New("the recorded project is missing from the reduced list")
				}
				results <- err
			}()
		}
		wg.Wait()
	})
	close(results)
	for err := range results {
		if err != nil {
			t.Errorf("concurrent call failed: %v", err)
		}
	}
	if used := client.nextOperation.Load(); used != callers {
		t.Errorf("client numbered %d operations, want %d", used, callers)
	}
}

func TestReduceRecentProjects(t *testing.T) {
	client := NewClient()
	ctx := testContext(t)
	first := time.UnixMilli(1_700_000_000_000)
	second := first.Add(time.Minute)
	third := first.Add(2 * time.Minute)

	one := RecentProject{Path: "/projects/one", LastOpenedAt: first.UnixMilli()}
	two := RecentProject{Path: "/projects/two", LastOpenedAt: second.UnixMilli()}

	// Record the first project into an empty list.
	result, err := client.ReduceRecentProjects(ctx, nil, RecordRecent(one.Path, first), 0)
	if err != nil {
		t.Fatalf("record one: %v", err)
	}
	if want := []RecentProject{one}; !slices.Equal(result.Entries, want) {
		t.Fatalf("entries = %+v, want %+v", result.Entries, want)
	}
	if want := []string{one.Path}; !slices.Equal(result.Added, want) || len(result.Removed) != 0 {
		t.Fatalf("added, removed = %q, %q, want %q, none", result.Added, result.Removed, want)
	}

	// Record a second one: it moves to the front.
	result, err = client.ReduceRecentProjects(ctx, result.Entries, RecordRecent(two.Path, second), 0)
	if err != nil {
		t.Fatalf("record two: %v", err)
	}
	if want := []RecentProject{two, one}; !slices.Equal(result.Entries, want) {
		t.Fatalf("entries = %+v, want %+v", result.Entries, want)
	}
	if want := []string{two.Path}; !slices.Equal(result.Added, want) || len(result.Removed) != 0 {
		t.Fatalf("added, removed = %q, %q, want %q, none", result.Added, result.Removed, want)
	}

	// Pin the older one: pinned projects come first.
	result, err = client.ReduceRecentProjects(ctx, result.Entries, TogglePinnedRecent(one.Path), 0)
	if err != nil {
		t.Fatalf("toggle pin: %v", err)
	}
	pinnedOne := RecentProject{Path: one.Path, LastOpenedAt: one.LastOpenedAt, Pinned: true}
	if want := []RecentProject{pinnedOne, two}; !slices.Equal(result.Entries, want) {
		t.Fatalf("entries = %+v, want %+v", result.Entries, want)
	}
	if len(result.Added) != 0 || len(result.Removed) != 0 {
		t.Fatalf("added, removed = %q, %q, want none", result.Added, result.Removed)
	}

	// A capacity of one unpinned entry drops the older unpinned project; the pin is exempt.
	three := RecentProject{Path: "/projects/three", LastOpenedAt: third.UnixMilli()}
	result, err = client.ReduceRecentProjects(ctx, result.Entries, RecordRecent(three.Path, third), 1)
	if err != nil {
		t.Fatalf("record three: %v", err)
	}
	if want := []RecentProject{pinnedOne, three}; !slices.Equal(result.Entries, want) {
		t.Fatalf("entries = %+v, want %+v", result.Entries, want)
	}
	if want := []string{three.Path}; !slices.Equal(result.Added, want) {
		t.Fatalf("added = %q, want %q", result.Added, want)
	}
	if want := []string{two.Path}; !slices.Equal(result.Removed, want) {
		t.Fatalf("removed = %q, want %q", result.Removed, want)
	}

	// Remove the pinned project.
	result, err = client.ReduceRecentProjects(ctx, result.Entries, RemoveRecent(one.Path, "/projects/unknown"), 0)
	if err != nil {
		t.Fatalf("remove: %v", err)
	}
	if want := []RecentProject{three}; !slices.Equal(result.Entries, want) {
		t.Fatalf("entries = %+v, want %+v", result.Entries, want)
	}
	if want := []string{one.Path}; !slices.Equal(result.Removed, want) || len(result.Added) != 0 {
		t.Fatalf("added, removed = %q, %q, want none, %q", result.Added, result.Removed, want)
	}
}

func TestReduceRecentProjectsImportAndNormalize(t *testing.T) {
	client := NewClient()
	ctx := testContext(t)
	base := time.UnixMilli(1_700_000_000_000)
	known := RecentProject{Path: "/projects/known", LastOpenedAt: base.UnixMilli() + 5000}

	imported := ImportRecent([]string{"/projects/x", "/projects/known", "/projects/y"}, base)
	result, err := client.ReduceRecentProjects(ctx, []RecentProject{known}, imported, 0)
	if err != nil {
		t.Fatalf("import: %v", err)
	}
	// The first new path is stamped base and the next one a millisecond older; the known path is
	// untouched.
	want := []RecentProject{
		known,
		{Path: "/projects/x", LastOpenedAt: base.UnixMilli()},
		{Path: "/projects/y", LastOpenedAt: base.UnixMilli() - 1},
	}
	if !slices.Equal(result.Entries, want) {
		t.Fatalf("entries = %+v, want %+v", result.Entries, want)
	}
	if wantAdded := []string{"/projects/x", "/projects/y"}; !slices.Equal(result.Added, wantAdded) {
		t.Fatalf("added = %q, want %q", result.Added, wantAdded)
	}

	// Normalize re-applies ordering: an unsorted list with a duplicate comes back sorted and
	// deduplicated, and nothing is reported as added.
	unsorted := []RecentProject{
		{Path: "/projects/old", LastOpenedAt: 10},
		{Path: "/projects/new", LastOpenedAt: 20},
		{Path: "/projects/old", LastOpenedAt: 5},
	}
	result, err = client.ReduceRecentProjects(ctx, unsorted, NormalizeRecent(), 0)
	if err != nil {
		t.Fatalf("normalize: %v", err)
	}
	wantSorted := []RecentProject{
		{Path: "/projects/new", LastOpenedAt: 20},
		{Path: "/projects/old", LastOpenedAt: 10},
	}
	if !slices.Equal(result.Entries, wantSorted) {
		t.Fatalf("entries = %+v, want %+v", result.Entries, wantSorted)
	}
	if len(result.Added) != 0 || len(result.Removed) != 0 {
		t.Fatalf("added, removed = %q, %q, want none", result.Added, result.Removed)
	}
}

func TestReduceRecentProjectsRejectsInvalidInput(t *testing.T) {
	client := NewClient()
	ctx := testContext(t)
	at := time.UnixMilli(1_700_000_000_000)

	tests := []struct {
		name     string
		action   RecentAction
		capacity int
	}{
		{"empty path", RecordRecent("", at), 0},
		{"capacity above the maximum", NormalizeRecent(), 201},
		{"negative capacity", NormalizeRecent(), -1},
		{"zero action", RecentAction{}, 0},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := client.ReduceRecentProjects(ctx, nil, tt.action, tt.capacity)
			requireCode(t, err, CodeInvalidRequest)
		})
	}
}

// chromeCatalog returns the catalog the chrome layout tests use: two panels on the upper left,
// one at the bottom left, and one plain button each on the title bar and the status bar.
func chromeCatalog() []ChromeItem {
	return []ChromeItem{
		{ID: "project", DefaultZone: ZoneLeftTop, Panel: true, OpenByDefault: true},
		{ID: "commit", DefaultZone: ZoneLeftTop, Panel: true},
		{ID: "git", DefaultZone: ZoneBottomLeft, Panel: true},
		{ID: "run", DefaultZone: ZoneTitleTrailing},
		{ID: "caret", DefaultZone: ZoneStatusTrailing},
	}
}

// zoneIDs returns the ids placed in zone, in display order.
func zoneIDs(layout ChromeLayout, zone Zone) []string {
	var ids []string
	for _, placement := range layout.Placements {
		if placement.Zone == zone {
			ids = append(ids, placement.ID)
		}
	}
	return ids
}

func TestReduceChromeLayout(t *testing.T) {
	client := NewClient()
	ctx := testContext(t)
	catalog := chromeCatalog()

	reduce := func(t *testing.T, state ChromeLayout, action ChromeAction) (ChromeLayout, bool) {
		t.Helper()
		layout, changed, err := client.ReduceChromeLayout(ctx, catalog, state, action)
		if err != nil {
			t.Fatalf("ReduceChromeLayout() error: %v", err)
		}
		return layout, changed
	}

	// Reset lays out every catalog item exactly once and opens the default panel.
	defaults, changed := reduce(t, ChromeLayout{}, ResetChrome())
	wantDefaults := ChromeLayout{
		Placements: []Placement{
			{ID: "project", Zone: ZoneLeftTop},
			{ID: "commit", Zone: ZoneLeftTop},
			{ID: "git", Zone: ZoneBottomLeft},
			{ID: "run", Zone: ZoneTitleTrailing},
			{ID: "caret", Zone: ZoneStatusTrailing},
		},
		Open: []string{"project"},
	}
	if !slices.Equal(defaults.Placements, wantDefaults.Placements) || !slices.Equal(defaults.Open, wantDefaults.Open) {
		t.Fatalf("reset = %+v, want %+v", defaults, wantDefaults)
	}
	if !changed {
		t.Error("reset of an empty state: changed = false, want true")
	}

	// Resetting the default layout again changes nothing.
	again, changed := reduce(t, defaults, ResetChrome())
	if changed || !slices.Equal(again.Placements, defaults.Placements) || !slices.Equal(again.Open, defaults.Open) {
		t.Errorf("second reset = %+v, changed %v, want the same layout unchanged", again, changed)
	}

	t.Run("move to another zone of the surface", func(t *testing.T) {
		layout, changed := reduce(t, defaults, MoveChrome("git", ZoneRightBottom, ""))
		if !changed {
			t.Error("changed = false, want true")
		}
		if got := zoneIDs(layout, ZoneRightBottom); !slices.Equal(got, []string{"git"}) {
			t.Errorf("right bottom = %q, want [git]", got)
		}
		if got := zoneIDs(layout, ZoneBottomLeft); len(got) != 0 {
			t.Errorf("bottom left = %q, want empty", got)
		}
		if len(layout.Placements) != len(catalog) {
			t.Errorf("placements = %+v, want every catalog item once", layout.Placements)
		}
	})

	// Right Bottom (the lower half of the right column) and Bottom Right (the right half of the
	// bottom area) are two zones, and so are Left Bottom and Bottom Left.
	t.Run("the bottom anchors are separate zones", func(t *testing.T) {
		layout, changed := reduce(t, defaults, MoveChrome("git", ZoneBottomRight, ""))
		if !changed {
			t.Error("changed = false, want true")
		}
		if got := zoneIDs(layout, ZoneBottomRight); !slices.Equal(got, []string{"git"}) {
			t.Errorf("bottom right = %q, want [git]", got)
		}
		if got := zoneIDs(layout, ZoneRightBottom); len(got) != 0 {
			t.Errorf("right bottom = %q, want empty", got)
		}

		layout, _ = reduce(t, defaults, MoveChrome("commit", ZoneLeftBottom, ""))
		if got := zoneIDs(layout, ZoneLeftBottom); !slices.Equal(got, []string{"commit"}) {
			t.Errorf("left bottom = %q, want [commit]", got)
		}
		if got := zoneIDs(layout, ZoneBottomLeft); !slices.Equal(got, []string{"git"}) {
			t.Errorf("bottom left = %q, want [git]", got)
		}
	})

	t.Run("move in front of another item", func(t *testing.T) {
		layout, _ := reduce(t, defaults, MoveChrome("commit", ZoneLeftTop, "project"))
		if got := zoneIDs(layout, ZoneLeftTop); !slices.Equal(got, []string{"commit", "project"}) {
			t.Errorf("left top = %q, want [commit project]", got)
		}
	})

	t.Run("move in front of itself changes nothing", func(t *testing.T) {
		_, changed := reduce(t, defaults, MoveChrome("run", ZoneTitleTrailing, "run"))
		if changed {
			t.Error("changed = true, want false")
		}
	})

	t.Run("an item never leaves its surface", func(t *testing.T) {
		_, _, err := client.ReduceChromeLayout(ctx, catalog, defaults, MoveChrome("project", ZoneStatusTrailing, ""))
		requireCode(t, err, CodeInvalidRequest)
		_, _, err = client.ReduceChromeLayout(ctx, catalog, defaults, MoveChrome("run", ZoneLeftTop, ""))
		requireCode(t, err, CodeInvalidRequest)
	})

	t.Run("toggle and set open", func(t *testing.T) {
		layout, changed := reduce(t, defaults, ToggleChrome("git"))
		if !changed || !slices.Equal(layout.Open, []string{"project", "git"}) {
			t.Fatalf("toggle git: open %q, changed %v, want [project git], true", layout.Open, changed)
		}
		// Opening a panel closes the other open panel of its zone.
		layout, changed = reduce(t, layout, ToggleChrome("commit"))
		if !changed || !slices.Equal(layout.Open, []string{"commit", "git"}) {
			t.Fatalf("toggle commit: open %q, changed %v, want [commit git], true", layout.Open, changed)
		}
		layout, changed = reduce(t, layout, SetChromeOpen("commit", false))
		if !changed || !slices.Equal(layout.Open, []string{"git"}) {
			t.Fatalf("close commit: open %q, changed %v, want [git], true", layout.Open, changed)
		}
		layout, changed = reduce(t, layout, SetChromeOpen("commit", false))
		if changed || !slices.Equal(layout.Open, []string{"git"}) {
			t.Fatalf("close commit again: open %q, changed %v, want [git], false", layout.Open, changed)
		}
		layout, changed = reduce(t, layout, ToggleChrome("git"))
		if !changed || len(layout.Open) != 0 || layout.Open == nil {
			t.Fatalf("toggle git closed: open %#v, changed %v, want a non-nil empty list, true", layout.Open, changed)
		}
	})

	t.Run("only known panels open", func(t *testing.T) {
		_, _, err := client.ReduceChromeLayout(ctx, catalog, defaults, ToggleChrome("run"))
		requireCode(t, err, CodeInvalidRequest)
		_, _, err = client.ReduceChromeLayout(ctx, catalog, defaults, ToggleChrome("missing"))
		requireCode(t, err, CodeInvalidRequest)
		_, _, err = client.ReduceChromeLayout(ctx, catalog, defaults, SetChromeOpen("caret", true))
		requireCode(t, err, CodeInvalidRequest)
	})

	t.Run("normalize repairs a saved layout", func(t *testing.T) {
		saved := ChromeLayout{
			Placements: []Placement{
				{ID: "gone", Zone: ZoneLeftTop},
				{ID: "caret", Zone: ZoneStatusTrailing},
			},
			Open: []string{"gone"},
		}
		layout, changed := reduce(t, saved, NormalizeChrome())
		if !changed {
			t.Error("changed = false, want true")
		}
		if len(layout.Placements) != len(catalog) {
			t.Fatalf("placements = %+v, want every catalog item once", layout.Placements)
		}
		for _, placement := range layout.Placements {
			if placement.ID == "gone" {
				t.Errorf("placements still list the removed item: %+v", layout.Placements)
			}
		}
		if len(layout.Open) != 0 {
			t.Errorf("open = %q, want none (the unknown panel is dropped and defaults are not applied)", layout.Open)
		}
		_, changed = reduce(t, layout, NormalizeChrome())
		if changed {
			t.Error("normalizing a normalized layout: changed = true, want false")
		}
	})

	t.Run("malformed catalog", func(t *testing.T) {
		repeated := []ChromeItem{
			{ID: "a", DefaultZone: ZoneLeftTop},
			{ID: "a", DefaultZone: ZoneLeftBottom},
		}
		_, _, err := client.ReduceChromeLayout(ctx, repeated, ChromeLayout{}, ResetChrome())
		requireCode(t, err, CodeInvalidRequest)
	})

	t.Run("zero action", func(t *testing.T) {
		_, _, err := client.ReduceChromeLayout(ctx, catalog, defaults, ChromeAction{})
		requireCode(t, err, CodeInvalidRequest)
	})
}

func TestRecentActionJSON(t *testing.T) {
	tests := []struct {
		name   string
		action RecentAction
		want   string
	}{
		{"record", RecordRecent("/p", time.UnixMilli(1500)), `{"kind":"record","path":"/p","openedAt":1500}`},
		{"remove", RemoveRecent("/a", "/b"), `{"kind":"remove","paths":["/a","/b"]}`},
		{"remove nothing", RemoveRecent(), `{"kind":"remove","paths":[]}`},
		{"toggle pinned", TogglePinnedRecent("/p"), `{"kind":"togglePinned","path":"/p"}`},
		{"import", ImportRecent([]string{"/a", "/b"}, time.UnixMilli(9)), `{"kind":"import","paths":["/a","/b"],"openedAt":9}`},
		{"import nothing", ImportRecent(nil, time.UnixMilli(9)), `{"kind":"import","paths":[],"openedAt":9}`},
		{"normalize", NormalizeRecent(), `{"kind":"normalize"}`},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := json.Marshal(tt.action)
			if err != nil {
				t.Fatalf("Marshal() error: %v", err)
			}
			if string(got) != tt.want {
				t.Fatalf("Marshal() = %s, want %s", got, tt.want)
			}
		})
	}

	if _, err := json.Marshal(RecentAction{}); err == nil {
		t.Fatal("Marshal() of the zero RecentAction succeeded, want an error")
	}
}

func TestRecentActionDoesNotAliasCallerSlices(t *testing.T) {
	paths := []string{"/a", "/b"}
	action := ImportRecent(paths, time.UnixMilli(9))
	paths[0] = "/changed"
	got, err := json.Marshal(action)
	if err != nil {
		t.Fatalf("Marshal() error: %v", err)
	}
	if want := `{"kind":"import","paths":["/a","/b"],"openedAt":9}`; string(got) != want {
		t.Fatalf("Marshal() = %s, want %s", got, want)
	}
}

func TestChromeJSON(t *testing.T) {
	tests := []struct {
		name  string
		value any
		want  string
	}{
		{"normalize", NormalizeChrome(), `{"kind":"normalize"}`},
		{"reset", ResetChrome(), `{"kind":"reset"}`},
		{"move to the end", MoveChrome("git", ZoneRightTop, ""), `{"kind":"move","id":"git","zone":"rightTop"}`},
		{"move before", MoveChrome("git", ZoneRightTop, "run"), `{"kind":"move","id":"git","zone":"rightTop","before":"run"}`},
		{"toggle", ToggleChrome("git"), `{"kind":"toggle","id":"git"}`},
		{"set open", SetChromeOpen("git", false), `{"kind":"setOpen","id":"git","open":false}`},
		{"empty layout", ChromeLayout{}, `{"placements":[],"open":[]}`},
		{"layout", ChromeLayout{Placements: []Placement{{ID: "a", Zone: ZoneLeftTop}}, Open: []string{"a"}}, `{"placements":[{"id":"a","zone":"leftTop"}],"open":["a"]}`},
		{"plain item", ChromeItem{ID: "a", DefaultZone: ZoneLeftTop}, `{"id":"a","defaultZone":"leftTop"}`},
		{"panel item", ChromeItem{ID: "a", DefaultZone: ZoneLeftTop, Panel: true, OpenByDefault: true}, `{"id":"a","defaultZone":"leftTop","panel":true,"openByDefault":true}`},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := json.Marshal(tt.value)
			if err != nil {
				t.Fatalf("Marshal() error: %v", err)
			}
			if string(got) != tt.want {
				t.Fatalf("Marshal() = %s, want %s", got, tt.want)
			}
		})
	}

	if _, err := json.Marshal(ChromeAction{}); err == nil {
		t.Fatal("Marshal() of the zero ChromeAction succeeded, want an error")
	}
}

func TestZoneValues(t *testing.T) {
	want := map[Zone]string{
		ZoneLeftTop:        "leftTop",
		ZoneLeftBottom:     "leftBottom",
		ZoneBottomLeft:     "bottomLeft",
		ZoneRightTop:       "rightTop",
		ZoneRightBottom:    "rightBottom",
		ZoneBottomRight:    "bottomRight",
		ZoneTitleTrailing:  "titleTrailing",
		ZoneStatusTrailing: "statusTrailing",
	}
	for zone, name := range want {
		if string(zone) != name {
			t.Errorf("zone %q, want %q", zone, name)
		}
	}
}

// isolateGit keeps the host's Git configuration out of the tests: an empty global configuration
// file, no system configuration, and no prompts. The kernel starts git from this process, so it
// sees the same environment. Tests that call it must not run in parallel.
func isolateGit(t *testing.T) {
	t.Helper()
	home := t.TempDir()
	config := filepath.Join(home, "gitconfig")
	writeFile(t, config, "")
	t.Setenv("HOME", home)
	t.Setenv("USERPROFILE", home)
	t.Setenv("GIT_CONFIG_GLOBAL", config)
	t.Setenv("GIT_CONFIG_NOSYSTEM", "1")
	t.Setenv("GIT_TERMINAL_PROMPT", "0")
}

// requireGit skips the test when no git executable is installed, then isolates Git. The tests
// that call it are the integration tests of this file: they need the installed git executable on
// top of the linked kernel, and every other test here runs without any external tool.
func requireGit(t *testing.T) {
	t.Helper()
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git executable not found")
	}
	isolateGit(t)
}

// runGit runs git with the given arguments in dir and fails the test when it fails.
func runGit(t *testing.T, dir string, args ...string) string {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), testDeadline)
	defer cancel()
	full := append([]string{
		"-c", "user.name=Lithe Test",
		"-c", "user.email=test@example.invalid",
		"-c", "commit.gpgsign=false",
	}, args...)
	cmd := exec.CommandContext(ctx, "git", full...)
	cmd.Dir = dir
	output, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %s: %v\n%s", strings.Join(args, " "), err, output)
	}
	return strings.TrimSpace(string(output))
}

// newRepository creates an empty repository whose unborn branch is main.
func newRepository(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	runGit(t, dir, "init")
	runGit(t, dir, "symbolic-ref", "HEAD", "refs/heads/main")
	return dir
}

// plainDirectory returns an empty directory that no Git repository contains. Git's search for a
// repository stops at the directory's parent, so a repository around the system temporary
// directory cannot turn the directory into part of it. The path is fully resolved, because Git
// compares the ceiling with its resolved working directory and does not follow symbolic links in
// the ceiling (the macOS temporary directory is behind one). Tests that call it must not run in
// parallel.
func plainDirectory(t *testing.T) string {
	t.Helper()
	dir, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatalf("resolve temporary directory: %v", err)
	}
	t.Setenv("GIT_CEILING_DIRECTORIES", filepath.Dir(dir))
	return dir
}

func TestGitStatus(t *testing.T) {
	requireGit(t)
	client := NewClient()
	ctx := testContext(t)
	repo := newRepository(t)

	empty, err := client.GitStatus(ctx, repo)
	if err != nil {
		t.Fatalf("GitStatus() on a clean repository error: %v", err)
	}
	if empty.RepositoryRoot != "." || empty.Branch != "main" {
		t.Errorf("repository root, branch = %q, %q, want %q, %q", empty.RepositoryRoot, empty.Branch, ".", "main")
	}
	if empty.Changes == nil || len(empty.Changes) != 0 {
		t.Errorf("changes = %#v, want a non-nil empty slice", empty.Changes)
	}

	writeFile(t, filepath.Join(repo, "new.txt"), "new")
	status, err := client.GitStatus(ctx, repo)
	if err != nil {
		t.Fatalf("GitStatus() with an untracked file error: %v", err)
	}
	if status.RepositoryRoot == "" || status.Branch == "" {
		t.Fatalf("repository root, branch = %q, %q, want both set", status.RepositoryRoot, status.Branch)
	}
	if len(status.Changes) != 1 {
		t.Fatalf("changes = %+v, want exactly new.txt", status.Changes)
	}
	change := status.Changes[0]
	if change.Path != "new.txt" || !change.Untracked || change.Staged {
		t.Fatalf("change = %+v, want new.txt untracked and not staged", change)
	}

	runGit(t, repo, "add", "new.txt")
	status, err = client.GitStatus(ctx, repo)
	if err != nil {
		t.Fatalf("GitStatus() with a staged file error: %v", err)
	}
	if len(status.Changes) != 1 || status.Changes[0].Path != "new.txt" || !status.Changes[0].Staged || status.Changes[0].Untracked {
		t.Fatalf("changes = %+v, want new.txt staged and tracked", status.Changes)
	}
}

func TestGitStatusOutsideRepository(t *testing.T) {
	requireGit(t)
	dir := plainDirectory(t)

	status, err := NewClient().GitStatus(testContext(t), dir)
	if err != nil {
		t.Fatalf("GitStatus() outside a repository error: %v, want success with an empty status", err)
	}
	if status.RepositoryRoot != "" || status.Branch != "" || status.Ahead != 0 || status.Behind != 0 {
		t.Errorf("status = %+v, want no repository identity", status)
	}
	if status.Changes == nil || len(status.Changes) != 0 {
		t.Errorf("changes = %#v, want a non-nil empty slice", status.Changes)
	}
}

func TestGitStatusMissingDirectory(t *testing.T) {
	_, err := NewClient().GitStatus(testContext(t), filepath.Join(t.TempDir(), "missing"))
	requireCode(t, err, CodeWorkspaceNotFound)
}
