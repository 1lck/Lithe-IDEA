package workbench

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/gfx"
)

// vcsFixtureManifest declares a version control provider answered by its own process: the copied
// test binary, started with TestVcsProviderFixture. Core detects its working copy by the .fakevcs
// directory, validates every reply, and the host only routes the requests and shows the result.
const vcsFixtureManifest = `{
  "schemaVersion": 0,
  "id": "dev.lithe.test.provider-tests",
  "displayName": "VCS Fixture",
  "version": "1.0.0",
  "pluginAPIVersion": 0,
  "requires": {"vcsProviders": 0},
  "vendor": {"id": "dev.lithe.test", "displayName": "Test", "signatureRequirement": "publisherPackage"},
  "permissions": ["languageServer.launch", "process.vcs"],
  "activationEvents": ["onVcsRoot:fakevcs"],
  "languages": [],
  "vcsProviders": [{
    "id": "fakevcs",
    "displayName": "Fake VCS",
    "detection": {"markers": [{"name": ".fakevcs", "type": "directory"}]},
    "metadataPaths": [".fakevcs/db"],
    "launch": {"kind": "packaged", "path": "provider"},
    "arguments": ["-test.run=^TestVcsProviderFixture$"],
    "mayUseNetwork": false
  }]
}`

// vcsFixtureID is the catalog item of the fixture's version control window.
const vcsFixtureID = vcsItemPrefix + "dev.lithe.test.provider-tests/fakevcs"

// TestVcsProviderFixture is the fixture provider process. The .fakevcs directory in its working
// directory, the opened project, tells it apart from an ordinary suite run. It keeps the working
// copy's changes in memory: check-in, rollback and resolve drop the paths they name, and the first
// two record their request under .fakevcs for the parent test to read.
func TestVcsProviderFixture(t *testing.T) {
	if info, err := os.Stat(".fakevcs"); err != nil || !info.IsDir() {
		t.Skip("not the version control fixture workspace")
	}
	changes := []map[string]any{
		{"path": "conflict.txt", "oldPath": nil, "status": "conflicted", "flags": []string{}},
		{"path": "notes.txt", "oldPath": nil, "status": "unversioned", "flags": []string{}},
		{"path": "src/gone.txt", "oldPath": nil, "status": "missing", "flags": []string{}},
		{"path": "src/main.txt", "oldPath": nil, "status": "modified", "flags": []string{}},
	}
	drop := func(paths []string) {
		changes = slices.DeleteFunc(changes, func(change map[string]any) bool {
			return slices.Contains(paths, change["path"].(string))
		})
	}
	reader := bufio.NewReader(os.Stdin)
	write := func(value any) {
		body, err := json.Marshal(value)
		if err != nil {
			os.Exit(2)
		}
		if _, err := fmt.Fprintf(os.Stdout, "Content-Length: %d\r\n\r\n%s", len(body), body); err != nil {
			os.Exit(3)
		}
	}
	reply := func(id json.RawMessage, result any) {
		write(map[string]any{"jsonrpc": "2.0", "id": id, "result": result})
	}
	record := func(name string, params json.RawMessage) {
		if err := os.WriteFile(filepath.Join(".fakevcs", name), params, 0o600); err != nil {
			os.Exit(8)
		}
	}
	revision := func(id string) map[string]any {
		return map[string]any{"id": id, "display": "r" + id, "kind": "number"}
	}
	for {
		length := -1
		for {
			line, err := reader.ReadString('\n')
			if err != nil {
				os.Exit(0)
			}
			line = strings.TrimSpace(line)
			if line == "" {
				break
			}
			if key, value, ok := strings.Cut(line, ":"); ok && strings.EqualFold(key, "Content-Length") {
				length, err = strconv.Atoi(strings.TrimSpace(value))
				if err != nil {
					os.Exit(4)
				}
			}
		}
		if length < 0 || length > 1<<20 {
			os.Exit(5)
		}
		body := make([]byte, length)
		if _, err := io.ReadFull(reader, body); err != nil {
			os.Exit(6)
		}
		var request struct {
			ID     json.RawMessage `json:"id"`
			Method string          `json:"method"`
			Params json.RawMessage `json:"params"`
		}
		if err := json.Unmarshal(body, &request); err != nil {
			os.Exit(7)
		}
		if len(request.ID) == 0 {
			continue
		}
		var params struct {
			Paths []string `json:"paths"`
		}
		_ = json.Unmarshal(request.Params, &params)
		switch request.Method {
		case "initialize":
			reply(request.ID, map[string]any{"capabilities": map[string]any{"experimental": map[string]any{
				"litheVcs": map[string]any{"version": 0, "vcs": "fakevcs", "capabilities": map[string]any{
					"status": 0, "baseContent": 0, "checkin": 0, "rollback": 0, "history": 0, "conflicts": 0,
				}},
			}}})
		case "lithe/vcs/status":
			reply(request.ID, map[string]any{
				"head":      map[string]any{"revision": revision("7"), "branch": nil, "location": "https://vcs.example.invalid/trunk"},
				"changes":   changes,
				"truncated": false,
			})
		case "lithe/vcs/baseContent":
			reply(request.ID, map[string]any{"content": "base line\n", "binary": false})
		case "lithe/vcs/checkin":
			record("checkin.json", request.Params)
			drop(params.Paths)
			reply(request.ID, map[string]any{"revision": revision("8")})
		case "lithe/vcs/rollback":
			record("rollback.json", request.Params)
			drop(params.Paths)
			reply(request.ID, map[string]any{})
		case "lithe/vcs/resolve":
			drop(params.Paths)
			reply(request.ID, map[string]any{})
		case "lithe/vcs/history":
			reply(request.ID, map[string]any{
				"entries": []any{map[string]any{
					"revision": revision("7"), "author": "alice", "date": "2026-11-01T10:00:00Z",
					"message":          "Initial import\nmore",
					"changes":          []any{map[string]any{"path": "src/main.txt", "oldPath": nil, "status": "added", "flags": []string{}}},
					"changesTruncated": false,
				}},
				"nextCursor": nil,
			})
		case "shutdown":
			reply(request.ID, nil)
		case "exit":
			os.Exit(0)
		default:
			reply(request.ID, nil)
		}
	}
}

// vcsFixtureRequest is what the fixture recorded of a check-in or rollback.
type vcsFixtureRequest struct {
	Paths   []string `json:"paths"`
	Message string   `json:"message"`
	Root    struct {
		Path string `json:"path"`
	} `json:"root"`
}

func readVcsFixtureRequest(t *testing.T, root, name string) vcsFixtureRequest {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(root, ".fakevcs", name))
	if err != nil {
		t.Fatalf("the provider did not receive the request: %v", err)
	}
	var request vcsFixtureRequest
	if err := json.Unmarshal(data, &request); err != nil {
		t.Fatalf("decode %s: %v", data, err)
	}
	return request
}

// vcsCommitButton is the Commit button of the version control window, the one across the
// window from the row of path: the stripe button of the Commit tool window has the same name.
func (h *harness) vcsCommitButton(path string) gfx.Rect {
	h.t.Helper()
	row := h.pageHit(path).Bounds
	for _, hit := range h.driver.Snapshot().Hits {
		if hit.Label == h.app.text.Commit.Commit && hit.Role == gfx.RoleButton && !hit.IsLabel &&
			hit.Bounds.X >= row.X && hit.Bounds.X < row.X+row.Width && hit.Bounds.Y > row.Y {
			return hit.Bounds
		}
	}
	h.t.Fatal("the version control window shows no Commit button")
	return gfx.Rect{}
}

// The version control window of a plugin provider lists the working copy's changes under their
// sections, opens a change's diff against the base revision, rolls back, commits only what is
// included, resolves a conflict and reads the history, every step through the provider.
func TestVcsProviderWindowListsCommitsAndRollsBack(t *testing.T) {
	h := providerTestsHarnessWith(t, vcsFixtureManifest)
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, ".fakevcs"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, "src"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "src", "main.txt"), []byte("base line\nnew line\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	h.open(root)
	// A tall window shows every section of the changes over the commit area.
	if err := h.driver.Resize(1280, 1400); err != nil {
		t.Fatal(err)
	}
	h.settle()
	h.app.reloadPluginLanguages()
	h.settle()
	p := h.app.project
	awaitStateWithin(t, h, 20*time.Second, "the plugin's version control window", func() bool {
		_, ok := h.app.chrome.index[vcsFixtureID]
		return ok
	})
	h.chromeAction(core.SetChromeOpen(vcsFixtureID, true))

	var state *vcsRootView
	awaitStateWithin(t, h, 60*time.Second, "the provider's status", func() bool {
		view := p.vcs.views[vcsFixtureID]
		if view == nil {
			return false
		}
		state = view.roots[view.root]
		return state != nil && !state.loading && (state.status != nil || state.failure != "")
	})
	view := p.vcs.views[vcsFixtureID]
	if state.failure != "" || view.failure != "" {
		t.Fatalf("the status failed: %q %q", state.failure, view.failure)
	}
	for _, label := range []string{h.shared("native.conflicts"), h.shared("native.unversionedFiles"), "main.txt", "r7", "vcs.example.invalid/trunk"} {
		if !h.shows(label) {
			t.Fatalf("the window does not show %q", label)
		}
	}
	var workingCopy string
	for _, candidate := range p.vcs.detection.Roots {
		if candidate.ID == view.root {
			workingCopy = candidate.Path
		}
	}

	// A double click opens the read-only diff of the file against its base revision.
	at := center(h.pageHit("src/main.txt").Bounds)
	if err := h.driver.DoubleClick(at.X, at.Y); err != nil {
		t.Fatal(err)
	}
	h.await("the provider diff", func() bool {
		diff := p.diffs.showing(workingCopy, "vcs:fakevcs", "src/main.txt")
		return diff != nil && diff.file != nil
	})
	diff := p.diffs.showing(workingCopy, "vcs:fakevcs", "src/main.txt")
	if !diff.readOnly() || diff.file.Additions != 1 || diff.file.Deletions != 0 {
		t.Fatalf("diff = read-only %v, +%d -%d; want a read-only diff adding one line", diff.readOnly(), diff.file.Additions, diff.file.Deletions)
	}
	h.chromeAction(core.SetChromeOpen(vcsFixtureID, true))

	// Rolling back asks first, then sends the change's paths.
	h.rightClickNamed("src/gone.txt")
	h.click(center(h.menuItemHit(h.shared("native.rollBack.variant2"))))
	if !slices.Equal(view.rollback, []string{"src/gone.txt"}) {
		t.Fatalf("the rollback dialog holds %v", view.rollback)
	}
	h.clickNamed(h.shared("native.rollBack"))
	h.await("the rollback", func() bool { return view.busy == "" && state.change("src/gone.txt") == nil })
	if got := readVcsFixtureRequest(t, root, "rollback.json"); !slices.Equal(got.Paths, []string{"src/gone.txt"}) || got.Root.Path != workingCopy {
		t.Fatalf("rollback request = %+v, want src/gone.txt of %s", got, workingCopy)
	}

	// The commit holds only the versioned change; the conflict and the unversioned file stay out.
	h.app.post(func(*App) { view.message.SetText("Fix the main file") })
	h.settle()
	h.click(center(h.vcsCommitButton("notes.txt")))
	h.await("the check-in", func() bool { return view.busy == "" && state.change("src/main.txt") == nil })
	got := readVcsFixtureRequest(t, root, "checkin.json")
	if !slices.Equal(got.Paths, []string{"src/main.txt"}) || got.Message != "Fix the main file" {
		t.Fatalf("checkin request = %+v, want src/main.txt with the message", got)
	}
	if view.message.Text() != "" || !h.shows("r8") {
		t.Fatalf("after the check-in the message is %q and the new revision is shown: %v", view.message.Text(), h.shows("r8"))
	}

	// The conflict's context menu marks it resolved.
	h.rightClickNamed("conflict.txt")
	h.click(center(h.menuItemHit(h.shared("native.markAsResolved"))))
	h.await("the resolve", func() bool { return view.busy == "" && state.change("conflict.txt") == nil })
	if h.shows(h.shared("native.conflicts")) {
		t.Fatal("the conflicts section is still shown after the last conflict was resolved")
	}

	// The history page reads the provider's revisions.
	h.clickNamed(h.shared("native.history"))
	h.await("the history", func() bool { return state.historyLoaded && !state.historyLoading })
	if state.historyFailure != "" || len(state.history) != 1 || !h.shows("alice") || !h.shows("Initial import") {
		t.Fatalf("history = %+v, failure %q", state.history, state.historyFailure)
	}
}

// Detaching the build sessions while the plugins change leaves the runtime open: the project
// starts new provider sessions afterwards, and only closing the project refuses them.
func TestBuildRuntimeDetachKeepsTheRuntimeOpen(t *testing.T) {
	var runtime buildRuntime
	if clients := runtime.detach(false); len(clients) != 0 || runtime.closed || runtime.detached != 1 {
		t.Fatalf("detach for a plugin change: %d clients, closed %v, detached %d", len(clients), runtime.closed, runtime.detached)
	}
	if runtime.detach(true); !runtime.closed {
		t.Fatal("detach for a closing project left the runtime open")
	}
}
