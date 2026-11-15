package core

import (
	"context"
	"strings"
	"testing"
)

// TestDiagnosticsBundleCommands checks the wire shapes of the export's kernel calls against
// the real kernel: redacting a value and building a manifest, whose files come back sorted.
func TestDiagnosticsBundleCommands(t *testing.T) {
	c := NewClient()
	ctx := context.Background()

	plain, err := c.RedactText(ctx, "0.4.0")
	if err != nil || plain != "0.4.0" {
		t.Fatalf("RedactText(version) = %q, %v", plain, err)
	}
	redacted, err := c.RedactText(ctx, "token=ghp_0123456789abcdefghijABCDEFGHIJ012345 at /Users/someone/secret.txt")
	if err != nil || strings.Contains(redacted, "ghp_0123456789") || strings.Contains(redacted, "/Users/someone") {
		t.Fatalf("RedactText(secret) = %q, %v", redacted, err)
	}

	environment := DiagnosticsEnvironment{
		AppVersion: "0.1.0", OsName: "macOS", OsVersion: "27.3", CpuCoreCount: 8,
		MemoryRssBytes: 1 << 20, DiskFreeBytes: 1 << 30,
	}
	manifest, err := c.BuildDiagnosticsManifest(ctx, environment, []DiagnosticsFile{
		{RelativePath: "logs/sessions/b/app.jsonl", SizeBytes: 12, Description: "evidence"},
		{RelativePath: "collection-status.txt", SizeBytes: 3, Description: "evidence"},
	}, 1_762_600_000_000)
	if err != nil {
		t.Fatalf("BuildDiagnosticsManifest: %v", err)
	}
	if manifest.SchemaVersion != 1 || manifest.Redaction == "" || manifest.GeneratedAtEpochMilliseconds != 1_762_600_000_000 {
		t.Fatalf("manifest = %+v", manifest)
	}
	if manifest.Environment != environment {
		t.Fatalf("manifest environment = %+v, want %+v", manifest.Environment, environment)
	}
	if len(manifest.Files) != 2 || manifest.Files[0].RelativePath != "collection-status.txt" || manifest.Files[1].SizeBytes != 12 {
		t.Fatalf("manifest files = %+v", manifest.Files)
	}

	empty, err := c.BuildDiagnosticsManifest(ctx, environment, nil, 0)
	if err != nil || empty.Files == nil || len(empty.Files) != 0 {
		t.Fatalf("BuildDiagnosticsManifest(no files) = %+v, %v", empty, err)
	}
}

// TestQueryLogsKeepsTheFilterRange checks that FilterSince and FilterUntil narrow a query the
// kernel already bounds by Since and Until.
func TestQueryLogsKeepsTheFilterRange(t *testing.T) {
	c := NewClient()
	ctx := context.Background()
	const started = "2026-11-08T09:30:00.000Z"
	batch, err := c.EncodeLogBatch(ctx, LogBatch{
		ValidateCatalog: true,
		Headers: []LogHeader{{
			Session: "0d949d58-1a39-4b8a-849f-44c765eb4a8c", Pid: 42, App: "0.1.0",
			Channel: "app", Started: started,
		}},
		Events: []LogEvent{
			{Ts: started, Level: LevelInfo, Seq: 1, Event: "app.session.started"},
			{Ts: "2026-11-08T09:31:00.000Z", Level: LevelInfo, Seq: 2, Event: "app.session.started"},
			{Ts: "2026-11-08T09:32:00.000Z", Level: LevelInfo, Seq: 3, Event: "app.session.started"},
		},
	})
	if err != nil {
		t.Fatalf("EncodeLogBatch: %v", err)
	}
	channel, err := c.ResolveLogChannel(ctx, "app", 0, nil)
	if err != nil {
		t.Fatalf("ResolveLogChannel: %v", err)
	}
	lines := []string{batch.Headers[0].Line}
	for _, result := range batch.Results {
		lines = append(lines, result.Line)
	}
	result, err := c.QueryLogs(ctx, LogQuery{
		Sources:     []LogSource{{RelativePath: batch.SessionPath + "/" + channel.RelativePath, Text: strings.Join(lines, "\n") + "\n"}},
		Since:       started,
		FilterSince: "2026-11-08T09:30:30.000Z",
		FilterUntil: "2026-11-08T09:31:30.000Z",
		Limit:       100,
	})
	if err != nil {
		t.Fatalf("QueryLogs: %v", err)
	}
	if len(result.Records) != 1 || result.Records[0].Seq != 2 {
		t.Fatalf("records = %+v, want only the second event", result.Records)
	}
}
