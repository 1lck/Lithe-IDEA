package core

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func readSharedJSON(t *testing.T, path string, value any) {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(append([]string{"..", "..", "..", "shared"}, filepath.SplitList(path)...)...))
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(data, value); err != nil {
		t.Fatal(err)
	}
}

func TestMcpToolsFixture(t *testing.T) {
	var fixture struct {
		PolicyRequest McpToolPolicyRequest `json:"policyRequest"`
		PolicyResult  McpToolPolicy        `json:"policyResult"`
		CommandLine   struct {
			Command string   `json:"command"`
			Args    []string `json:"args"`
		} `json:"commandLine"`
	}
	readSharedJSON(t, "fixtures/mcp/tools-v1.json", &fixture)
	client := NewClient()
	policy, err := client.McpToolPolicy(testContext(t), fixture.PolicyRequest)
	if err != nil {
		t.Fatal(err)
	}
	if policy.Content != fixture.PolicyResult.Content || !policy.Changed || len(policy.Tools) != 1 ||
		policy.Tools[0].Enabled || !policy.Tools[0].Editable || !policy.HasRestrictions {
		t.Fatalf("policy = %#v", policy)
	}
	line, err := client.McpCommandLine(testContext(t), fixture.CommandLine.Command, fixture.CommandLine.Args)
	if err != nil {
		t.Fatal(err)
	}
	command, args, err := client.McpParseCommandLine(testContext(t), line)
	if err != nil {
		t.Fatal(err)
	}
	if command != fixture.CommandLine.Command || len(args) != 3 || args[0] != "" || args[2] != "a'b" {
		t.Fatalf("round trip = %q %q", command, args)
	}
}

func TestMcpRegistryFixtures(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("..", "..", "..", "shared", "contracts", "mcp-registry-page.json"))
	if err != nil {
		t.Fatal(err)
	}
	client := NewClient()
	page, err := client.McpParseRegistry(testContext(t), string(data))
	if err != nil {
		t.Fatal(err)
	}
	if len(page.Entries) != 3 || page.NextCursor == nil || *page.NextCursor != "opaque/+ cursor?" {
		t.Fatalf("page = %#v", page)
	}
	if page.Entries[0].Draft == nil || page.Entries[0].Draft.Transport != "http" || page.Entries[2].Draft != nil {
		t.Fatalf("drafts = %#v", page.Entries)
	}
	featured, err := client.McpFeaturedRegistry(testContext(t))
	if err != nil || len(featured.Entries) < 10 || featured.Entries[0].Source != "featured" {
		t.Fatalf("featured = %d %v", len(featured.Entries), err)
	}
}

func TestMcpLibrarySnapshotAndBatch(t *testing.T) {
	var fixture struct {
		Files map[string]McpLibraryFile `json:"files"`
	}
	readSharedJSON(t, "fixtures/mcp/library-v1.json", &fixture)
	files := []McpLibraryFile{fixture.Files["codexGlobal"], fixture.Files["claudeGlobal"], fixture.Files["claudeProject"]}
	for i := range files {
		files[i].Owned = []McpLedgerEntry{}
	}
	client := NewClient()
	snapshot, err := client.McpLibrarySnapshot(testContext(t), files)
	if err != nil {
		t.Fatal(err)
	}
	if len(snapshot.Failures) != 0 || len(snapshot.Rows) != 5 || snapshot.Rows[0].Definition.Name != "docs" ||
		len(snapshot.Rows[0].Sources) != 2 || snapshot.Rows[0].Definition.SourceHash == "" && snapshot.Rows[0].Sources[0].SourceHash == "" {
		t.Fatalf("snapshot = %#v", snapshot)
	}

	broken := fixture.Files["codexBroken"]
	broken.Owned = []McpLedgerEntry{}
	snapshot, err = client.McpLibrarySnapshot(testContext(t), []McpLibraryFile{broken})
	if err != nil || len(snapshot.Failures) != 1 || snapshot.Failures[0].Code != "invalid_request" {
		t.Fatalf("failures = %#v %v", snapshot, err)
	}

	// An unowned external entry is refused for automatic deletion.
	plan, err := client.McpBatchPlan(testContext(t), files[:2], McpBatchIntent{Kind: "delete", Name: "docs", Files: []string{files[1].ID}})
	if err != nil {
		t.Fatal(err)
	}
	if plan.Status != "ready" && (plan.Status != "rejected" || plan.Rejection == nil) {
		t.Fatalf("plan = %#v", plan)
	}
}

func TestMcpValidateDraft(t *testing.T) {
	validation, err := NewClient().McpValidateDraft(testContext(t), McpDraft{Name: " ", Transport: "stdio"})
	if err != nil {
		t.Fatal(err)
	}
	if validation.Definition != nil || len(validation.Issues) == 0 || validation.Issues[0].Code != "nameRequired" {
		t.Fatalf("validation = %#v", validation)
	}
	validation, err = NewClient().McpValidateDraft(testContext(t), McpDraft{Name: " docs ", Transport: "stdio", Command: "npx", EnabledAgents: []string{"codex"}})
	if err != nil || validation.Definition == nil || validation.Definition.Name != "docs" {
		t.Fatalf("validation = %#v %v", validation, err)
	}
}

func TestMcpPlanWriteRoundTrip(t *testing.T) {
	client := NewClient()
	content := "# keep\n[mcp_servers.a]\ncommand = \"x\"\n"
	plan, err := client.McpPlanWrite(testContext(t), McpPlanWriteRequest{
		Source: "codex", Scope: "global", Content: &content, Operation: "set",
		Server: &McpServer{Name: "b", Transport: "http", URL: "https://example.invalid/mcp"},
	})
	if err != nil {
		t.Fatal(err)
	}
	if plan.Action != "inserted" || !plan.Changed || plan.SourceHash == "" {
		t.Fatalf("plan = %#v", plan)
	}
	servers, err := client.McpParseConfiguration(testContext(t), McpParseConfigurationRequest{Source: "codex", Scope: "global", Content: plan.Content})
	if err != nil || len(servers) != 2 {
		t.Fatalf("servers = %#v %v", servers, err)
	}
}
