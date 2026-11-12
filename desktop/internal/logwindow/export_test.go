package logwindow

import (
	"archive/zip"
	"context"
	"encoding/json"
	"errors"
	"io"
	"maps"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/logstore"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/1lck/Lithe-IDEA/desktop/internal/sysinfo"
)

// settleLimit bounds how long a test waits for the model's background tasks.
const settleLimit = 10 * time.Second

// exportNow is the fixed clock of the export tests.
var exportNow = time.Date(2026, 11, 8, 9, 30, 0, 0, time.UTC)

// emitted is one event the window reported.
type emitted struct {
	level  core.LogLevel
	event  string
	fields map[string]any
}

// exportSource is a Source whose Collect returns a fixed export or error and which records
// the events the window emits. Only Collect and Emit are reached by an export.
type exportSource struct {
	dir string

	mu      sync.Mutex
	export  logstore.Export
	err     error
	queries []logstore.ExportQuery
	events  []emitted
}

func (s *exportSource) QueryWindow(context.Context, logstore.Query) (logstore.Collection, error) {
	return logstore.Collection{}, nil
}

func (s *exportSource) QueryWindowBatch(context.Context, []logstore.Batch, logstore.Query) (core.LogQueryResult, error) {
	return core.LogQueryResult{}, nil
}

func (s *exportSource) LiveSummary(context.Context, []core.LogRecord) (logstore.LiveSummary, error) {
	return logstore.LiveSummary{}, nil
}

func (s *exportSource) Subscribe(func([]logstore.Batch)) func() { return func() {} }
func (s *exportSource) UsedBytes() int64                        { return 0 }
func (s *exportSource) ChangeDirectory(string) error            { return nil }
func (s *exportSource) RestoreDefaultDirectory() error          { return nil }
func (s *exportSource) DefaultDirectory() string                { return s.dir }
func (s *exportSource) ClearLogs() error                        { return nil }
func (s *exportSource) ConfigureDiagnostics(bool)               {}

func (s *exportSource) Emit(level core.LogLevel, event, _ string, fields map[string]any) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.events = append(s.events, emitted{level: level, event: event, fields: fields})
}

func (s *exportSource) Collect(_ context.Context, q logstore.ExportQuery) (logstore.Export, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.queries = append(s.queries, q)
	export := s.export
	export.Files = slices.Clone(export.Files)
	return export, s.err
}

func (s *exportSource) fail(err error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.err = err
}

func (s *exportSource) emittedEvents() []emitted {
	s.mu.Lock()
	defer s.mu.Unlock()
	return slices.Clone(s.events)
}

// exportKernel redacts a home directory the way the kernel would and builds a manifest of
// the files it is given, recording what it was asked.
type exportKernel struct {
	mu          sync.Mutex
	environment core.DiagnosticsEnvironment
	generatedAt int64
}

func (k *exportKernel) ParseLogFilter(context.Context, string) (core.LogFilter, error) {
	return core.LogFilter{}, nil
}

func (k *exportKernel) ComposeLogFilter(_ context.Context, expression string, _ core.LogFilterTerm) (string, error) {
	return expression, nil
}

func (k *exportKernel) FormatLogRecords(context.Context, []string, string, *core.LogEnvironment) (string, error) {
	return "", nil
}

func (k *exportKernel) RedactText(_ context.Context, text string) (string, error) {
	return strings.ReplaceAll(text, "/Users/alice", "~"), nil
}

func (k *exportKernel) BuildDiagnosticsManifest(_ context.Context, environment core.DiagnosticsEnvironment, files []core.DiagnosticsFile, generatedAt int64) (core.DiagnosticsManifest, error) {
	k.mu.Lock()
	defer k.mu.Unlock()
	k.environment, k.generatedAt = environment, generatedAt
	return core.DiagnosticsManifest{
		Redaction:                    "core-v2",
		SchemaVersion:                1,
		GeneratedAtEpochMilliseconds: generatedAt,
		Environment:                  environment,
		Files:                        slices.Clone(files),
	}, nil
}

// exportFixture is a model with a fake source and kernel, a cache directory and a folder to
// save bundles in.
type exportFixture struct {
	model  *Model
	source *exportSource
	kernel *exportKernel
	cache  string
	saves  string
	// saveTo is what the save dialog answers; empty is a cancelled choice.
	saveTo string
}

const exportLogPath = "logs/sessions/2026-11-08/app.jsonl"

func newExportFixture(t testing.TB) *exportFixture {
	t.Helper()
	logs := t.TempDir()
	fx := &exportFixture{
		source: &exportSource{dir: logs, export: logstore.Export{
			Files: []logstore.ExportFile{
				{RelativePath: exportLogPath, Data: []byte("{\"event\":\"app.session.started\"}\n")},
				{RelativePath: "collection-status.txt", Data: []byte("truncated=false dropped_events=0 write_failures=0 skipped_invalid_lines=0\n")},
			},
			Directory:      logs,
			EstimatedBytes: 4096,
			Sessions:       []string{"2026-11-08"},
		}},
		kernel: &exportKernel{},
		cache:  t.TempDir(),
		saves:  t.TempDir(),
	}
	fx.model = NewModel(Options{
		Source: fx.source,
		Kernel: fx.kernel,
		Now:    func() time.Time { return exportNow },
		Environment: func() core.LogEnvironment {
			return core.LogEnvironment{AppVersion: "1.2.3", OsVersion: "macOS 27.3", Architecture: "arm64", Plugins: []string{"/Users/alice/plugins/java"}}
		},
		SaveFile:       func(string) (string, error) { return fx.saveTo, nil },
		CacheDirectory: func() (string, error) { return fx.cache, nil },
		System: func(volume string) sysinfo.Snapshot {
			return sysinfo.Snapshot{OSName: "macOS", OSVersion: "Version 27.3", CPUCores: 8, ResidentBytes: 1 << 20, DiskFreeBytes: 1 << 30}
		},
	})
	t.Cleanup(func() {
		fx.model.close()
		settle(t, fx.model)
	})
	return fx
}

// settle waits, within settleLimit, until the model's background tasks have returned and
// their results are applied.
func settle(t testing.TB, m *Model) {
	t.Helper()
	done := make(chan struct{})
	go func() {
		defer close(done)
		m.wait()
	}()
	select {
	case <-done:
	case <-time.After(settleLimit):
		t.Fatalf("background tasks still running after %v; export phase %d", settleLimit, m.export.phase)
	}
}

// stagingRoots lists the staging directories left in the cache directory.
func (fx *exportFixture) stagingRoots(t *testing.T) []string {
	t.Helper()
	parent := filepath.Join(fx.cache, store.Directory, exportStagingFolder)
	entries, err := os.ReadDir(parent)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		t.Fatalf("read staging directories: %v", err)
	}
	roots := make([]string, 0, len(entries))
	for _, entry := range entries {
		roots = append(roots, filepath.Join(parent, entry.Name()))
	}
	return roots
}

// staged presents the dialog and waits for its evidence to be staged.
func (fx *exportFixture) staged(t *testing.T) string {
	t.Helper()
	fx.model.presentExport()
	settle(t, fx.model)
	e := &fx.model.export
	if e.phase != exportAwaiting || e.manifest == nil || e.root == "" {
		t.Fatalf("after staging: phase %d, manifest %v, root %q, failed stage %q", e.phase, e.manifest != nil, e.root, e.failedStage)
	}
	return e.root
}

func zipEntries(t *testing.T, path string) map[string]string {
	t.Helper()
	archive, err := zip.OpenReader(path)
	if err != nil {
		t.Fatalf("open archive: %v", err)
	}
	defer archive.Close()
	entries := map[string]string{}
	for _, file := range archive.File {
		if strings.HasSuffix(file.Name, "/") {
			entries[file.Name] = ""
			continue
		}
		reader, err := file.Open()
		if err != nil {
			t.Fatalf("open %s: %v", file.Name, err)
		}
		data, err := io.ReadAll(reader)
		reader.Close()
		if err != nil {
			t.Fatalf("read %s: %v", file.Name, err)
		}
		entries[file.Name] = string(data)
	}
	return entries
}

// TestExportStagesTheEvidenceAndPacksIt checks the whole export: the dialog stages the
// records, a redacted environment summary and the kernel's manifest in the cache directory,
// saving packs that folder into the archive and the staging directory is removed.
func TestExportStagesTheEvidenceAndPacksIt(t *testing.T) {
	fx := newExportFixture(t)
	fx.model.presentExport()
	if fx.model.export.phase != exportPreparing || !fx.model.export.presented {
		t.Fatalf("presenting: phase %d, presented %v", fx.model.export.phase, fx.model.export.presented)
	}
	settle(t, fx.model)
	e := &fx.model.export
	if e.phase != exportAwaiting || e.manifest == nil {
		t.Fatalf("phase %d, failed stage %q", e.phase, e.failedStage)
	}
	if e.estimatedBytes != 4096 || e.fileCount() != 4 {
		t.Fatalf("estimated %d bytes in %d files, want 4096 in the records, status, environment and manifest", e.estimatedBytes, e.fileCount())
	}
	if want := filepath.Join(fx.cache, store.Directory, exportStagingFolder); filepath.Dir(e.root) != want {
		t.Fatalf("staging root %q is not under %q", e.root, want)
	}
	if e.manifest.Redaction != "core-v2" || fx.kernel.generatedAt != exportNow.UnixMilli() {
		t.Fatalf("manifest redaction %q generated at %d", e.manifest.Redaction, fx.kernel.generatedAt)
	}
	if env := fx.kernel.environment; env.AppVersion != "1.2.3" || env.OsName != "macOS" || env.CpuCoreCount != 8 || env.DiskFreeBytes != 1<<30 {
		t.Fatalf("manifest environment = %+v", env)
	}
	var paths []string
	for _, file := range e.manifest.Files {
		paths = append(paths, file.RelativePath)
		if file.Description != exportFileDescription || file.SizeBytes == 0 {
			t.Fatalf("manifest file = %+v", file)
		}
	}
	if want := []string{exportLogPath, "collection-status.txt", "environment.json"}; !slices.Equal(paths, want) {
		t.Fatalf("manifest files = %v, want %v", paths, want)
	}
	if q := fx.source.queries; len(q) != 1 || q[0].Session != sessionCurrent {
		t.Fatalf("collected %+v, want the current session once", q)
	}

	root := e.root
	destination := filepath.Join(fx.saves, "bundle.zip")
	fx.model.exportTo(destination)
	if e.phase != exportExporting || !fx.model.exportBusy() {
		t.Fatalf("packing: phase %d", e.phase)
	}
	settle(t, fx.model)
	if e.phase != exportCompleted || e.destination != destination || e.root != "" {
		t.Fatalf("after packing: phase %d, destination %q, root %q", e.phase, e.destination, e.root)
	}
	if _, err := os.Stat(root); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("staging root still there after the export: %v", err)
	}
	if saved, err := os.ReadDir(fx.saves); err != nil || len(saved) != 1 {
		t.Fatalf("save folder holds %v (%v), want only the archive", saved, err)
	}

	entries := zipEntries(t, destination)
	for name := range entries {
		if !strings.HasPrefix(name, exportFolder+"/") {
			t.Fatalf("archive entry %q is outside %q", name, exportFolder)
		}
	}
	if got := entries[exportFolder+"/"+exportLogPath]; got != "{\"event\":\"app.session.started\"}\n" {
		t.Fatalf("archived records = %q", got)
	}
	for _, name := range []string{"collection-status.txt", "manifest.json", "environment.json"} {
		if _, ok := entries[exportFolder+"/"+name]; !ok {
			t.Fatalf("archive lacks %s: %v", name, slices.Sorted(maps.Keys(entries)))
		}
	}
	var environment core.LogEnvironment
	if err := json.Unmarshal([]byte(entries[exportFolder+"/environment.json"]), &environment); err != nil {
		t.Fatalf("environment.json: %v", err)
	}
	if environment.Architecture != "arm64" || !slices.Equal(environment.Plugins, []string{"~/plugins/java"}) {
		t.Fatalf("environment.json = %+v, want the client's description redacted", environment)
	}
	var manifest core.DiagnosticsManifest
	if err := json.Unmarshal([]byte(entries[exportFolder+"/manifest.json"]), &manifest); err != nil || manifest.Redaction != "core-v2" || len(manifest.Files) != 3 {
		t.Fatalf("manifest.json = %+v (%v)", manifest, err)
	}
	if events := fx.source.emittedEvents(); len(events) != 0 {
		t.Fatalf("a successful export emitted %+v", events)
	}
}

// TestChangingAChoiceStagesAgain checks that a new choice stages the evidence again and
// removes what the old one staged.
func TestChangingAChoiceStagesAgain(t *testing.T) {
	fx := newExportFixture(t)
	first := fx.staged(t)

	fx.model.setExportEnvironment(false)
	settle(t, fx.model)
	e := &fx.model.export
	if e.phase != exportAwaiting || e.root == first || e.fileCount() != 3 {
		t.Fatalf("after replanning: phase %d, root %q, %d files", e.phase, e.root, e.fileCount())
	}
	if _, err := os.Stat(filepath.Join(e.root, exportFolder, "environment.json")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("environment.json staged without the environment: %v", err)
	}
	if roots := fx.stagingRoots(t); !slices.Equal(roots, []string{e.root}) {
		t.Fatalf("staging roots = %v, want only %q", roots, e.root)
	}
}

// TestDismissingTheDialogRemovesItsStaging checks that cancelling the dialog drops the
// staged evidence.
func TestDismissingTheDialogRemovesItsStaging(t *testing.T) {
	fx := newExportFixture(t)
	fx.staged(t)

	fx.model.dismissExport()
	settle(t, fx.model)
	e := &fx.model.export
	if e.presented || e.phase != exportIdle || e.root != "" || e.manifest != nil {
		t.Fatalf("after dismissing: presented %v, phase %d, root %q", e.presented, e.phase, e.root)
	}
	if roots := fx.stagingRoots(t); len(roots) != 0 {
		t.Fatalf("staging roots left: %v", roots)
	}
}

// TestClosingTheWindowRemovesTheStaging checks that a window closed with the dialog open
// leaves nothing in the cache directory.
func TestClosingTheWindowRemovesTheStaging(t *testing.T) {
	fx := newExportFixture(t)
	fx.staged(t)

	fx.model.close()
	settle(t, fx.model)
	if roots := fx.stagingRoots(t); len(roots) != 0 {
		t.Fatalf("staging roots left after closing: %v", roots)
	}
}

// TestAFailedCollectionReportsThePlanningStage checks that evidence that cannot be collected
// shows the failure, reports it as the planning stage and stages nothing.
func TestAFailedCollectionReportsThePlanningStage(t *testing.T) {
	fx := newExportFixture(t)
	fx.source.fail(errors.New("log directory unreadable"))

	fx.model.presentExport()
	settle(t, fx.model)
	e := &fx.model.export
	if e.phase != exportFailed || e.failedStage != stagePlanning {
		t.Fatalf("phase %d, failed stage %q", e.phase, e.failedStage)
	}
	events := fx.source.emittedEvents()
	if len(events) != 1 || events[0].event != exportFailedEvent || events[0].level != core.LevelError || events[0].fields["stage"] != stagePlanning {
		t.Fatalf("events = %+v", events)
	}
	if roots := fx.stagingRoots(t); len(roots) != 0 {
		t.Fatalf("a failed plan staged %v", roots)
	}

	fx.source.fail(nil)
	fx.model.replanExport()
	settle(t, fx.model)
	if e.phase != exportAwaiting || e.failedStage != "" {
		t.Fatalf("after retrying: phase %d, failed stage %q", e.phase, e.failedStage)
	}
}

// TestAFailedArchiveReportsTheArchiveStage checks that a bundle that cannot be written
// reports the archive stage, keeps its staging until Retry, and that Retry stages anew.
func TestAFailedArchiveReportsTheArchiveStage(t *testing.T) {
	fx := newExportFixture(t)
	root := fx.staged(t)

	fx.model.exportTo(filepath.Join(fx.saves, "missing", "bundle.zip"))
	settle(t, fx.model)
	e := &fx.model.export
	if e.phase != exportFailed || e.failedStage != stageArchive || e.root != root {
		t.Fatalf("phase %d, failed stage %q, root %q", e.phase, e.failedStage, e.root)
	}
	events := fx.source.emittedEvents()
	if len(events) != 1 || events[0].event != exportFailedEvent || events[0].fields["stage"] != stageArchive {
		t.Fatalf("events = %+v", events)
	}
	if saved, err := os.ReadDir(fx.saves); err != nil || len(saved) != 0 {
		t.Fatalf("save folder holds %v (%v) after a failed archive", saved, err)
	}

	fx.model.replanExport()
	settle(t, fx.model)
	if e.phase != exportAwaiting || e.root == root {
		t.Fatalf("after retrying: phase %d, root %q", e.phase, e.root)
	}
	if roots := fx.stagingRoots(t); !slices.Equal(roots, []string{e.root}) {
		t.Fatalf("staging roots = %v, want only %q", roots, e.root)
	}
}

// TestConfirmingAsksWhereToSave checks the Export button: a cancelled save dialog keeps the
// staged bundle, a chosen path saves it there.
func TestConfirmingAsksWhereToSave(t *testing.T) {
	fx := newExportFixture(t)
	fx.staged(t)
	e := &fx.model.export

	fx.model.confirmExport()
	if !e.choosing || !fx.model.exportBusy() {
		t.Fatal("the save dialog does not lock the choices")
	}
	settle(t, fx.model)
	if e.phase != exportAwaiting || e.choosing || e.root == "" {
		t.Fatalf("after a cancelled choice: phase %d, choosing %v, root %q", e.phase, e.choosing, e.root)
	}

	fx.saveTo = filepath.Join(fx.saves, "chosen.zip")
	fx.model.confirmExport()
	settle(t, fx.model)
	if e.phase != exportCompleted || e.destination != fx.saveTo {
		t.Fatalf("after choosing: phase %d, destination %q", e.phase, e.destination)
	}
	if _, err := os.Stat(fx.saveTo); err != nil {
		t.Fatalf("bundle not saved: %v", err)
	}
}

// TestExportQueryFollowsTheChoices checks what each range and the filter option collect.
func TestExportQueryFollowsTheChoices(t *testing.T) {
	fx := newExportFixture(t)
	e := &fx.model.export
	e.filter = windowQuery{
		Session:         sessionAll,
		Expression:      "event:app.session.started",
		ChannelPrefixes: []string{"lsp"},
		Levels:          []core.LogLevel{core.LevelError},
		Since:           "2026-11-07T00:00:00Z",
		Until:           "2026-11-08T00:00:00Z",
	}

	e.scope = exportCurrent
	if q := fx.model.exportQuery(); q.Session != sessionCurrent || q.RecentSessions != 0 || q.Since != "" || q.ChannelPrefixes != nil || q.Expression != "" {
		t.Fatalf("current session = %+v", q)
	}
	e.scope = exportRecent
	if q := fx.model.exportQuery(); q.Session != sessionAll || q.RecentSessions != exportRecentSessions {
		t.Fatalf("recent sessions = %+v", q)
	}
	e.scope = exportDay
	if q := fx.model.exportQuery(); q.Session != sessionAll || q.Since != "2026-11-07T09:30:00Z" {
		t.Fatalf("last 24 hours = %+v", q)
	}

	e.scope, e.currentFilterOnly = exportCurrent, true
	q := fx.model.exportQuery()
	if q.Session != sessionCurrent || q.Expression != e.filter.Expression ||
		!slices.Equal(q.ChannelPrefixes, e.filter.ChannelPrefixes) || !slices.Equal(q.Levels, e.filter.Levels) ||
		q.FilterSince != e.filter.Since || q.FilterUntil != e.filter.Until {
		t.Fatalf("current filter = %+v", q)
	}
	q.ChannelPrefixes[0] = "changed"
	if e.filter.ChannelPrefixes[0] != "lsp" {
		t.Fatal("the export query shares the window filter's channels")
	}
}

// TestBundlePathStaysInsideTheFolder checks that a file of the bundle cannot be staged
// outside its folder.
func TestBundlePathStaysInsideTheFolder(t *testing.T) {
	content := t.TempDir()
	if path, err := bundlePath(content, "logs/sessions/app.jsonl"); err != nil || path != filepath.Join(content, "logs", "sessions", "app.jsonl") {
		t.Fatalf("bundlePath = %q, %v", path, err)
	}
	for _, relative := range []string{"../escape.txt", "logs/../../escape.txt", "/etc/passwd", ""} {
		if path, err := bundlePath(content, relative); err == nil {
			t.Fatalf("bundlePath(%q) = %q, want an error", relative, path)
		}
	}
}
