package core

import (
	"context"
	"strings"
	"testing"
)

// TestLoggingRoundTrip encodes a session's first lines with the real kernel, queries them back
// and formats the record, so every wire shape the log store uses is checked against the kernel.
func TestLoggingRoundTrip(t *testing.T) {
	c := NewClient()
	ctx := context.Background()
	const started = "2026-11-08T09:30:00.000Z"
	batch, err := c.EncodeLogBatch(ctx, LogBatch{
		ValidateCatalog: true,
		Deduplicate:     true,
		Headers: []LogHeader{{
			Session: "0d949d58-1a39-4b8a-849f-44c765eb4a8c", Pid: 42, App: "0.1.0",
			Channel: "app", Started: started,
		}},
		Events: []LogEvent{
			{Ts: started, Level: LevelInfo, Seq: 1, Event: "app.session.started"},
			{Ts: "2026-11-08T09:30:01.000Z", Level: LevelInfo, Seq: 2, Event: "app.action.performed",
				Fields: map[string]any{"action": "open_project", "surface": "button"}},
			{Ts: started, Level: LevelInfo, Seq: 3, Event: "no.such.event"},
		},
	})
	if err != nil {
		t.Fatalf("EncodeLogBatch: %v", err)
	}
	if !strings.HasPrefix(batch.SessionPath, "sessions/2026-11-08T") || len(batch.Headers) != 1 || batch.Headers[0].Line == "" {
		t.Fatalf("headers = %+v, session path %q", batch.Headers, batch.SessionPath)
	}
	if len(batch.Results) != 3 || batch.Results[0].Line == "" || batch.Results[1].Channel != "app" || batch.Results[2].Error == nil {
		t.Fatalf("results = %+v", batch.Results)
	}

	path, err := c.ResolveLogChannel(ctx, "app", 0, nil)
	if err != nil || path.RelativePath == "" {
		t.Fatalf("ResolveLogChannel = %+v, %v", path, err)
	}

	text := batch.Headers[0].Line + "\n" + batch.Results[0].Line + "\n" + batch.Results[1].Line + "\n"
	result, err := c.QueryLogs(ctx, LogQuery{
		Sources:          []LogSource{{RelativePath: batch.SessionPath + "/" + path.RelativePath, Text: text}},
		Limit:            100,
		HistogramBuckets: 10,
	})
	if err != nil {
		t.Fatalf("QueryLogs: %v", err)
	}
	if len(result.Records) != 2 || result.Records[1].Event != "app.action.performed" || result.Records[1].Fields["action"] != "open_project" {
		t.Fatalf("records = %+v", result.Records)
	}
	if result.Histogram == nil || len(result.Histogram.Buckets) == 0 || result.Channels["app"].Total != 2 {
		t.Fatalf("histogram = %+v, channels = %+v", result.Histogram, result.Channels)
	}

	filter, err := c.ParseLogFilter(ctx, "level>=warn -event:lsp.trace.received")
	if err != nil || len(filter.Terms) != 2 || len(filter.Errors) != 0 {
		t.Fatalf("ParseLogFilter = %+v, %v", filter, err)
	}
	composed, err := c.ComposeLogFilter(ctx, "", LogFilterTerm{Kind: "channel", Value: "app"})
	if err != nil || composed == "" {
		t.Fatalf("ComposeLogFilter = %q, %v", composed, err)
	}
	formatted, err := c.FormatLogRecords(ctx, []string{result.Records[1].Line}, "json", nil)
	if err != nil || !strings.Contains(formatted, "open_project") {
		t.Fatalf("FormatLogRecords = %q, %v", formatted, err)
	}

	plan, err := c.PlanLogCollection(ctx, LogCollectionRequest{
		Files:          []LogFile{{RelativePath: batch.SessionPath + "/" + path.RelativePath, SizeBytes: uint64(len(text)), ModifiedAt: started}},
		CurrentSession: strings.TrimPrefix(batch.SessionPath, "sessions/"),
		Session:        "current",
	})
	if err != nil || len(plan.Reads) != 1 {
		t.Fatalf("PlanLogCollection = %+v, %v", plan, err)
	}
	if _, err := c.PlanLogRetention(ctx, LogRetentionRequest{CurrentSession: strings.TrimPrefix(batch.SessionPath, "sessions/"), Now: started}); err != nil {
		t.Fatalf("PlanLogRetention: %v", err)
	}
	if err := c.ConfigureCoreEvents(ctx, false, nil); err != nil {
		t.Fatalf("ConfigureCoreEvents: %v", err)
	}
	if _, err := c.DrainCoreEvents(ctx); err != nil {
		t.Fatalf("DrainCoreEvents: %v", err)
	}
}

// TestEncodeLogBatchPreviousWithoutFields checks that a previous event without fields takes
// part in deduplication like one with an empty map of them, which the kernel needs and the
// log store relies on, and that the caller's batch is left as it was.
func TestEncodeLogBatchPreviousWithoutFields(t *testing.T) {
	c := NewClient()
	ctx := context.Background()
	event := LogEvent{Ts: "2026-11-08T09:30:00.000Z", Level: LevelInfo, Seq: 1, Event: "app.session.started"}
	encode := func(previous *LogEvent) EncodedLog {
		t.Helper()
		next := event
		next.Seq = 2
		events := []LogEvent{next}
		batch, err := c.EncodeLogBatch(ctx, LogBatch{
			ValidateCatalog: true,
			Deduplicate:     true,
			Previous:        previous,
			Events:          events,
		})
		if err != nil || len(batch.Results) != 1 {
			t.Fatalf("EncodeLogBatch = %+v, %v", batch, err)
		}
		if events[0].Fields != nil || (previous != nil && previous.Fields != nil && len(previous.Fields) != 0) {
			t.Fatalf("the batch was modified: %+v, previous %+v", events, previous)
		}
		return batch.Results[0]
	}

	without := encode(nil)
	bare := event
	nilFields := encode(&bare)
	if bare.Fields != nil {
		t.Fatalf("the previous event was modified: %+v", bare)
	}
	empty := event
	empty.Fields = map[string]any{}
	emptyFields := encode(&empty)

	if nilFields != emptyFields {
		t.Fatalf("previous without fields = %+v, with empty fields = %+v", nilFields, emptyFields)
	}
	if nilFields == without {
		t.Fatalf("the previous event did not take part in deduplication: %+v", nilFields)
	}
}
