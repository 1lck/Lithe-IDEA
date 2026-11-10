package mcpconfig

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

func testContext(t *testing.T) context.Context {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	t.Cleanup(cancel)
	return ctx
}

func newService(t *testing.T) (*Service, Environment, string) {
	t.Helper()
	home := t.TempDir()
	env := Environment{Home: home}
	return New(core.NewClient(), env, filepath.Join(t.TempDir(), "data")), env, home
}

func write(t *testing.T, path, text string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(text), 0o600); err != nil {
		t.Fatal(err)
	}
}

func read(t *testing.T, path string) string {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

const codexText = "# keep this comment\n[mcp_servers.docs]\ncommand = \"npx\"\nargs = [\"-y\", \"docs-mcp\"]\nstartup_timeout_sec = 30\n"

func TestLocationsFollowTheToolsOwnDirectories(t *testing.T) {
	env := Environment{Home: "/h", Getenv: func(name string) string {
		return map[string]string{"CODEX_HOME": "/c", "CLAUDE_CONFIG_DIR": "/d"}[name]
	}}
	files := Locations(env, "/p")
	got := []string{files[0].Path, files[1].Path, files[2].Path, files[3].Path}
	want := []string{"/c/config.toml", "/d/.claude.json", "/d/.claude.json", "/p/.codex/config.toml"}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("paths = %v, want %v", got, want)
		}
	}
	if len(Locations(env, "")) != 2 {
		t.Fatal("project files listed without a project")
	}
}

func TestLoadShowsTheRealConfigurationAndWritesNothing(t *testing.T) {
	service, env, _ := newService(t)
	write(t, env.CodexConfigPath(), codexText)
	lib, err := service.Load(testContext(t), "")
	if err != nil {
		t.Fatal(err)
	}
	if len(lib.Snapshot.Rows) != 1 || lib.Snapshot.Rows[0].Definition.Name != "docs" || lib.Snapshot.Rows[0].Sources[0].OwnedByLithe {
		t.Fatalf("rows = %#v", lib.Snapshot.Rows)
	}
	if _, err := os.Stat(service.dataDir); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("opening the library wrote to the data directory")
	}
}

func saveIntent(name string, agents ...string) core.McpBatchIntent {
	return core.McpBatchIntent{Kind: "save", Draft: &core.McpDraft{
		Name: name, Transport: "http", URL: "https://example.invalid/mcp", EnabledAgents: agents,
	}}
}

func TestSavePreservesCommentsBacksUpAndRecordsOwnership(t *testing.T) {
	service, env, _ := newService(t)
	write(t, env.CodexConfigPath(), codexText)
	plan, err := service.Apply(testContext(t), "", saveIntent("new-docs", "codex", "claude"))
	if err != nil || plan.Status != "ready" {
		t.Fatalf("plan = %#v %v", plan, err)
	}
	codex := read(t, env.CodexConfigPath())
	if !strings.Contains(codex, "# keep this comment") || !strings.Contains(codex, "startup_timeout_sec = 30") || !strings.Contains(codex, "new-docs") {
		t.Fatalf("codex = %q", codex)
	}
	if !strings.Contains(read(t, env.ClaudeConfigPath()), "new-docs") {
		t.Fatal("claude entry missing")
	}
	backups, _ := filepath.Glob(filepath.Join(service.dataDir, "MCP Backups", "*", "config.toml"))
	if len(backups) != 1 || read(t, backups[0]) != codexText {
		t.Fatalf("backups = %v", backups)
	}
	lib, err := service.Load(testContext(t), "")
	if err != nil {
		t.Fatal(err)
	}
	owned := map[string]bool{}
	for _, row := range lib.Snapshot.Rows {
		for _, source := range row.Sources {
			owned[row.Definition.Name+"|"+source.File] = source.OwnedByLithe
		}
	}
	if !owned["new-docs|codex|global|"] || !owned["new-docs|claude|global|"] || owned["docs|codex|global|"] {
		t.Fatalf("ownership = %v", owned)
	}
}

func TestDeleteRefusesAnEntryLitheDidNotWrite(t *testing.T) {
	service, env, _ := newService(t)
	write(t, env.CodexConfigPath(), codexText)
	plan, err := service.Apply(testContext(t), "", core.McpBatchIntent{Kind: "delete", Name: "docs", Files: []string{"codex|global|"}})
	if err != nil {
		t.Fatal(err)
	}
	if plan.Status != "rejected" || plan.Rejection == nil || plan.Rejection.Code != "notOwned" {
		t.Fatalf("plan = %#v", plan)
	}
	if read(t, env.CodexConfigPath()) != codexText {
		t.Fatal("a refused delete changed the file")
	}
}

func TestEditOfAnExternalEntryNeedsTheHashTheUserSaw(t *testing.T) {
	service, env, _ := newService(t)
	write(t, env.CodexConfigPath(), codexText)
	lib, err := service.Load(testContext(t), "")
	if err != nil {
		t.Fatal(err)
	}
	source := lib.Snapshot.Rows[0].Sources[0]
	draft := &core.McpDraft{Name: "docs", Transport: "stdio", Command: "npx", Arguments: []string{"-y", "docs-mcp@2"}, EnabledAgents: []string{"codex"}}
	original := &core.McpOriginal{Name: "docs", Sources: []core.McpOriginalSource{{File: source.File, SourceHash: source.SourceHash}}}

	// Someone else edits the entry after the user opened it.
	write(t, env.CodexConfigPath(), strings.Replace(codexText, "30", "99", 1))
	plan, err := service.Apply(testContext(t), "", core.McpBatchIntent{Kind: "save", Draft: draft, Original: original})
	if err != nil || plan.Status != "rejected" || plan.Rejection.Code != "externallyModified" {
		t.Fatalf("stale edit = %#v %v", plan, err)
	}
	if !strings.Contains(read(t, env.CodexConfigPath()), "99") || strings.Contains(read(t, env.CodexConfigPath()), "@2") {
		t.Fatal("the external edit was overwritten")
	}

	// With the current hash the edit goes through and keeps the unmodeled field.
	lib, _ = service.Load(testContext(t), "")
	source = lib.Snapshot.Rows[0].Sources[0]
	original.Sources[0].SourceHash = source.SourceHash
	plan, err = service.Apply(testContext(t), "", core.McpBatchIntent{Kind: "save", Draft: draft, Original: original})
	if err != nil || plan.Status != "ready" {
		t.Fatalf("edit = %#v %v", plan, err)
	}
	text := read(t, env.CodexConfigPath())
	if !strings.Contains(text, "docs-mcp@2") || !strings.Contains(text, "startup_timeout_sec = 99") || !strings.Contains(text, "# keep this comment") {
		t.Fatalf("text = %q", text)
	}
}

func TestFailedBatchRestoresTheFilesAlreadyWritten(t *testing.T) {
	service, env, _ := newService(t)
	write(t, env.CodexConfigPath(), codexText)
	if os.Geteuid() == 0 {
		t.Skip("permissions do not stop root")
	}
	// Claude's directory is read-only, so publishing its file fails after Codex's succeeded.
	locked := filepath.Join(t.TempDir(), "claude")
	write(t, filepath.Join(locked, ".claude.json"), "{}\n")
	service.env.Getenv = func(name string) string {
		if name == "CLAUDE_CONFIG_DIR" {
			return locked
		}
		return ""
	}
	if err := os.Chmod(locked, 0o500); err != nil {
		t.Fatal(err)
	}
	defer os.Chmod(locked, 0o700)
	_, err := service.Apply(testContext(t), "", saveIntent("x", "codex", "claude"))
	var failure *WriteError
	if !errors.As(err, &failure) {
		t.Fatalf("err = %v", err)
	}
	if read(t, env.CodexConfigPath()) != codexText {
		t.Fatalf("codex was not restored: %q", read(t, env.CodexConfigPath()))
	}
	if _, statErr := os.Stat(service.ledgerPath()); !errors.Is(statErr, os.ErrNotExist) {
		t.Fatal("a ledger was published for a failed batch")
	}
}

func TestUnreadableFileRefusesTheWrite(t *testing.T) {
	service, env, _ := newService(t)
	write(t, env.CodexConfigPath(), codexText)
	write(t, env.ClaudeConfigPath(), string([]byte{0xff, 0xfe}))
	if _, err := service.Apply(testContext(t), "", saveIntent("x", "codex")); !errors.Is(err, ErrUnreadable) {
		t.Fatalf("err = %v", err)
	}
	if read(t, env.CodexConfigPath()) != codexText {
		t.Fatal("a refused write changed a file")
	}
}

func TestToolPolicyOnlyEditsOwnRules(t *testing.T) {
	service, env, _ := newService(t)
	write(t, env.ClaudeSettingsPath(), "{\"permissions\":{\"deny\":[\"mcp__docs__write\"]}}\n")
	policy, err := service.ToolPolicy(testContext(t), "claude", "docs", []string{"read", "write"})
	if err != nil {
		t.Fatal(err)
	}
	editable := map[string]bool{}
	for _, tool := range policy.Tools {
		editable[tool.Name] = tool.Editable
	}
	if editable["write"] || !editable["read"] {
		t.Fatalf("policy = %#v", policy)
	}
	policy, err = service.SetTool(testContext(t), "claude", "docs", []string{"read", "write"}, "read", false)
	if err != nil || !policy.Changed {
		t.Fatalf("set = %#v %v", policy, err)
	}
	text := read(t, env.ClaudeSettingsPath())
	if !strings.Contains(text, "mcp__docs__read") || !strings.Contains(text, "mcp__docs__write") {
		t.Fatalf("settings = %q", text)
	}
	policy, err = service.SetTool(testContext(t), "claude", "docs", []string{"read", "write"}, "read", true)
	if err != nil || strings.Contains(read(t, env.ClaudeSettingsPath()), "mcp__docs__read") || !strings.Contains(read(t, env.ClaudeSettingsPath()), "mcp__docs__write") {
		t.Fatalf("re-enable = %v %q", err, read(t, env.ClaudeSettingsPath()))
	}
}
