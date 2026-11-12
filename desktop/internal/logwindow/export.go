package logwindow

// The export of a diagnostic bundle: the dialog's choices, the staged evidence it shows and
// the archive it writes. The macOS client's DiagnosticsFeatureModel and
// DiagnosticsExportService are the reference.
//
// Opening the dialog, or changing one of its choices, freezes the evidence: the kernel's
// redacted records, the environment summary and the kernel's manifest of them are written to
// a staging directory before the dialog offers to save, and saving only packs that directory.
// Nothing is read again after the dialog shows what the bundle holds.
//
// Lifecycle of the staging directory. It is <user cache>/Lithe Desktop/diagnostics-export/<id>,
// a directory of the platform's cache, never inside the application bundle or the
// installation directory, so it changes neither a signature nor the bytes an update is
// computed from. The dialog owns it: a new plan, a cancellation, a finished export and the
// window's closing remove it. While a task writes or packs it, that task holds it (see
// claimStaging), and whatever ends last removes it.

import (
	"archive/zip"
	"context"
	"encoding/json"
	"errors"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/logstore"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/1lck/Lithe-IDEA/desktop/internal/sysinfo"
)

// exportRange is which sessions a bundle covers.
type exportRange int

const (
	exportCurrent exportRange = iota
	exportRecent
	exportDay
)

// exportPhase is where the export of a bundle is.
type exportPhase int

const (
	// exportIdle has nothing staged.
	exportIdle exportPhase = iota
	// exportPreparing collects and stages the evidence.
	exportPreparing
	// exportAwaiting has the evidence staged and waits for the user to save it.
	exportAwaiting
	// exportExporting packs the staged evidence.
	exportExporting
	// exportCompleted has saved the bundle at the destination.
	exportCompleted
	// exportFailed could not stage or save; failedStage says which.
	exportFailed
)

const (
	// exportFolder is the folder of a bundle: the staging directory holds it and the
	// archive has it at its root.
	exportFolder = "Lithe Diagnostics"
	// exportStagingFolder is the staging directories' parent in the cache directory.
	exportStagingFolder = "diagnostics-export"
	// exportRecentSessions is how many sessions "Last 3 sessions" covers.
	exportRecentSessions = 3
	// exportFileDescription is the manifest's description of every file.
	exportFileDescription = "Core-redacted diagnostic evidence"
	exportFailedEvent     = "app.diagnostics.export_failed"
	// The stages of exportFailedEvent the window reports.
	// maxExportFiles is the most log files one bundle holds; the rest are counted in exportStatusFile.
	maxExportFiles = 200
	// exportStatusFile reports what the bundle left out.
	exportStatusFile = "collection-status.txt"
	// previewLifetime is how long a staged preview stays exportable; after it the staging is removed and
	// the preview is planned again.
	previewLifetime = 5 * time.Minute
	stagePlanning   = "planning"
	stageArchive    = "archive"
	stageCleanup    = "cleanup"
)

// exportState is the export dialog's state.
type exportState struct {
	presented bool
	// stagedAt is when the staged preview was made; an older preview is planned again.
	stagedAt time.Time
	// The dialog's choices.
	scope              exportRange
	currentFilterOnly  bool
	includeEnvironment bool
	// filter and environment are the window's query and client description when the dialog
	// opened; nil environment is a client that has none.
	filter      windowQuery
	environment *core.LogEnvironment

	phase       exportPhase
	failedStage string
	// manifest is the staged bundle's; nil until one is staged.
	manifest       *core.DiagnosticsManifest
	estimatedBytes uint64
	// root is the staging directory of manifest; empty when nothing is staged.
	root string
	// destination is where the completed bundle was saved.
	destination string
	// generation tells a plan's results from those of a plan that replaced it.
	generation int
	cancel     context.CancelFunc
	// choosing says the save dialog is open.
	choosing bool
}

// exportBusy says the dialog's choices are locked: a bundle is being saved, the user picks
// where, or the window moves or clears the logs.
func (m *Model) exportBusy() bool {
	return m.export.phase == exportExporting || m.export.choosing || m.busy
}

// presentExport opens the export dialog with its default choices and stages the evidence
// they select.
func (m *Model) presentExport() {
	if m.exportBusy() {
		return
	}
	e := &m.export
	e.filter = m.prefs.Query.clone()
	e.environment = nil
	if m.opts.Environment != nil {
		environment := m.opts.Environment()
		e.environment = &environment
	}
	e.scope, e.currentFilterOnly, e.includeEnvironment = exportCurrent, false, true
	e.presented = true
	m.replanExport()
}

func (m *Model) setExportRange(scope exportRange) {
	if m.export.scope == scope {
		return
	}
	m.export.scope = scope
	m.replanExport()
}

func (m *Model) setExportFilterOnly(only bool) {
	if m.export.currentFilterOnly == only {
		return
	}
	m.export.currentFilterOnly = only
	m.replanExport()
}

func (m *Model) setExportEnvironment(include bool) {
	if m.export.includeEnvironment == include {
		return
	}
	m.export.includeEnvironment = include
	m.replanExport()
}

// replanExport stages the evidence again for the dialog's choices. Retry does the same.
func (m *Model) replanExport() {
	if !m.export.presented || m.exportBusy() {
		return
	}
	m.cancelExport()
	m.prepareExport()
}

// dismissExport closes the dialog and drops what it staged. A bundle being packed finishes,
// and the task packing it removes the staging directory.
func (m *Model) dismissExport() {
	m.export.choosing = false
	m.cancelExport()
	m.export.presented = false
}

// cancelExport abandons the plan and removes what it staged, unless an archive is packing it.
func (m *Model) cancelExport() {
	e := &m.export
	e.generation++
	if e.cancel != nil {
		e.cancel()
		e.cancel = nil
	}
	if e.root != "" && e.phase != exportExporting {
		m.removeStaging(e.root)
	}
	e.root, e.manifest, e.phase, e.failedStage = "", nil, exportIdle, ""
}

// exportQuery is what the dialog's choices select.
func (m *Model) exportQuery() logstore.ExportQuery {
	e := &m.export
	var q logstore.ExportQuery
	switch e.scope {
	case exportCurrent:
		q.Session = sessionCurrent
	case exportRecent:
		q.Session, q.RecentSessions = sessionAll, exportRecentSessions
	case exportDay:
		q.Session = sessionAll
		q.Since = m.now().Add(-24 * time.Hour).UTC().Format(time.RFC3339)
	}
	if e.currentFilterOnly {
		q.ChannelPrefixes = slices.Clone(e.filter.ChannelPrefixes)
		q.Levels = slices.Clone(e.filter.Levels)
		q.Expression = e.filter.Expression
		q.FilterSince, q.FilterUntil = e.filter.Since, e.filter.Until
	}
	return q
}

// prepareExport collects the evidence the dialog's choices select and stages it.
func (m *Model) prepareExport() {
	e := &m.export
	e.generation++
	token := e.generation
	e.root, e.manifest, e.phase, e.failedStage, e.estimatedBytes = "", nil, exportPreparing, "", 0
	ctx, cancel := context.WithCancel(m.ctx)
	e.cancel = cancel
	q := m.exportQuery()
	plan := stagingPlan{now: m.now(), includeEnvironment: e.includeEnvironment, defaultDirectory: m.defaultDirectory}
	if e.environment != nil {
		environment := *e.environment
		environment.Plugins = slices.Clone(environment.Plugins)
		plan.environment = &environment
		plan.appVersion = environment.AppVersion
	}
	m.spawn(func() {
		defer cancel()
		root, manifest, err := m.stage(ctx, token, q, plan)
		m.post(func() { m.staged(token, root, manifest, err) })
	})
}

// stagingPlan is what a plan stages besides the records, read on the window thread.
type stagingPlan struct {
	now time.Time
	// appVersion is the client's version the manifest records.
	appVersion string
	// includeEnvironment adds environment.json, the client's description or, without one,
	// what the system snapshot says.
	includeEnvironment bool
	environment        *core.LogEnvironment
	// defaultDirectory is the volume the system snapshot measures when the collection names
	// no log directory.
	defaultDirectory string
}

// stage collects the records and writes the bundle's folder: the records, the environment
// summary and the kernel's manifest of them. It runs on its own goroutine; on failure it
// removes what it wrote.
func (m *Model) stage(ctx context.Context, token int, q logstore.ExportQuery, plan stagingPlan) (string, *core.DiagnosticsManifest, error) {
	if m.opts.CacheDirectory == nil {
		return "", nil, errors.New("logwindow: no cache directory to stage a diagnostic bundle in")
	}
	collection, err := m.opts.Source.Collect(ctx, q)
	if err == nil {
		err = ctx.Err()
	}
	if err != nil {
		return "", nil, err
	}
	estimated := collection.EstimatedBytes
	m.post(func() {
		if token == m.export.generation {
			m.export.estimatedBytes = estimated
		}
	})
	cache, err := m.opts.CacheDirectory()
	if err != nil {
		return "", nil, err
	}
	root := filepath.Join(cache, store.Directory, exportStagingFolder, newID())
	if !m.claimStaging(root) {
		return "", nil, context.Canceled
	}
	manifest, err := m.writeStaging(ctx, root, collection, plan)
	if closed := m.releaseStaging(root); err == nil && closed {
		err = context.Canceled
	}
	if err != nil {
		m.removeStagingNow(root)
		return "", nil, err
	}
	return root, &manifest, nil
}

// writeStaging writes the bundle's folder under root and returns its manifest.
func (m *Model) writeStaging(ctx context.Context, root string, collection logstore.Export, plan stagingPlan) (core.DiagnosticsManifest, error) {
	content := filepath.Join(root, exportFolder)
	if err := os.MkdirAll(content, 0o700); err != nil {
		return core.DiagnosticsManifest{}, err
	}
	volume := collection.Directory
	if volume == "" {
		volume = plan.defaultDirectory
	}
	var snapshot sysinfo.Snapshot
	if m.opts.System != nil {
		snapshot = m.opts.System(volume)
	}
	files := slices.Clone(collection.Files)
	if omitted := len(files) - maxExportFiles; omitted > 0 {
		files = files[:maxExportFiles]
		status := []byte("files omitted by the " + strconv.Itoa(maxExportFiles) + "-file limit: " + strconv.Itoa(omitted) + "\n")
		files = append(files, logstore.ExportFile{RelativePath: exportStatusFile, Data: status})
	}
	if plan.includeEnvironment {
		summary := core.LogEnvironment{AppVersion: plan.appVersion, OsVersion: snapshot.OSVersion, Architecture: "unknown"}
		if plan.environment != nil {
			summary = *plan.environment
		}
		data, err := m.environmentSummary(ctx, summary)
		if err != nil {
			return core.DiagnosticsManifest{}, err
		}
		files = append(files, logstore.ExportFile{RelativePath: "environment.json", Data: data})
	}
	described := make([]core.DiagnosticsFile, 0, len(files))
	for _, file := range files {
		if err := ctx.Err(); err != nil {
			return core.DiagnosticsManifest{}, err
		}
		target, err := bundlePath(content, file.RelativePath)
		if err != nil {
			return core.DiagnosticsManifest{}, err
		}
		if err := os.MkdirAll(filepath.Dir(target), 0o700); err != nil {
			return core.DiagnosticsManifest{}, err
		}
		if err := writeAtomic(target, file.Data); err != nil {
			return core.DiagnosticsManifest{}, err
		}
		described = append(described, core.DiagnosticsFile{
			RelativePath: file.RelativePath,
			SizeBytes:    uint64(len(file.Data)),
			Description:  exportFileDescription,
		})
	}
	manifest, err := m.opts.Kernel.BuildDiagnosticsManifest(ctx, core.DiagnosticsEnvironment{
		AppVersion:     plan.appVersion,
		OsName:         snapshot.OSName,
		OsVersion:      snapshot.OSVersion,
		CpuCoreCount:   snapshot.CPUCores,
		MemoryRssBytes: snapshot.ResidentBytes,
		DiskFreeBytes:  snapshot.DiskFreeBytes,
	}, described, plan.now.UnixMilli())
	if err != nil {
		return core.DiagnosticsManifest{}, err
	}
	data, err := json.Marshal(manifest)
	if err != nil {
		return core.DiagnosticsManifest{}, err
	}
	if err := writeAtomic(filepath.Join(content, "manifest.json"), data); err != nil {
		return core.DiagnosticsManifest{}, err
	}
	return manifest, ctx.Err()
}

// environmentSummary is environment.json: the client's version, system, architecture and
// plugins, each value redacted by the kernel before it is encoded, so redaction can never
// break the JSON around it.
func (m *Model) environmentSummary(ctx context.Context, summary core.LogEnvironment) ([]byte, error) {
	redact := func(value string) (string, error) { return m.opts.Kernel.RedactText(ctx, value) }
	var safe core.LogEnvironment
	var err error
	if safe.AppVersion, err = redact(summary.AppVersion); err != nil {
		return nil, err
	}
	if safe.OsVersion, err = redact(summary.OsVersion); err != nil {
		return nil, err
	}
	if safe.Architecture, err = redact(summary.Architecture); err != nil {
		return nil, err
	}
	safe.Plugins = make([]string, 0, len(summary.Plugins))
	for _, plugin := range summary.Plugins {
		redacted, err := redact(plugin)
		if err != nil {
			return nil, err
		}
		safe.Plugins = append(safe.Plugins, redacted)
	}
	return json.Marshal(safe)
}

// staged applies a plan's result.
func (m *Model) staged(token int, root string, manifest *core.DiagnosticsManifest, err error) {
	e := &m.export
	if token != e.generation {
		if root != "" {
			m.removeStaging(root)
		}
		return
	}
	e.cancel = nil
	if err != nil {
		if errors.Is(err, context.Canceled) {
			e.phase = exportIdle
			return
		}
		m.exportFailure(stagePlanning, err)
		return
	}
	e.root, e.manifest, e.phase = root, manifest, exportAwaiting
	e.stagedAt = m.now()
}

// errPreviewExpired reports that a staged preview is older than previewLifetime.
var errPreviewExpired = errors.New("the diagnostic preview expired; prepare it again")

// confirmExport asks where to save the staged bundle and saves it there.
func (m *Model) confirmExport() {
	e := &m.export
	if e.phase != exportAwaiting || e.choosing || m.opts.SaveFile == nil {
		return
	}
	if m.now().Sub(e.stagedAt) > previewLifetime {
		// The frozen bytes are too old to save as previewed: the staging goes and the preview is made again.
		m.removeStaging(e.root)
		e.root, e.manifest, e.phase = "", nil, exportIdle
		m.exportFailure(stagePlanning, errPreviewExpired)
		return
	}
	e.choosing = true
	token := e.generation
	suggested := "lithe-logs-" + m.now().Format("2006-01-02-150405") + ".zip"
	m.spawn(func() {
		destination, err := m.opts.SaveFile(suggested)
		m.post(func() {
			if token != e.generation || !e.choosing {
				return
			}
			e.choosing = false
			switch {
			case err != nil:
				m.exportFailure(stageArchive, err)
			case destination != "":
				m.exportTo(destination)
			}
		})
	})
}

// exportTo packs the staged bundle into a zip archive at destination.
func (m *Model) exportTo(destination string) {
	e := &m.export
	if e.manifest == nil || e.root == "" || e.phase == exportExporting || e.phase == exportCompleted {
		return
	}
	root, token := e.root, e.generation
	if !m.claimStaging(root) {
		return
	}
	e.phase = exportExporting
	m.spawn(func() {
		err := zipFolder(filepath.Join(root, exportFolder), destination)
		if closed := m.releaseStaging(root); err == nil || closed {
			m.removeStagingNow(root)
		}
		m.post(func() { m.exported(token, root, destination, err) })
	})
}

// exported applies an archive's result.
func (m *Model) exported(token int, root, destination string, err error) {
	e := &m.export
	if token != e.generation {
		if err != nil {
			m.removeStaging(root)
		}
		return
	}
	if err != nil {
		if errors.Is(err, context.Canceled) {
			e.phase = exportAwaiting
			return
		}
		m.exportFailure(stageArchive, err)
		return
	}
	e.root, e.destination, e.phase = "", destination, exportCompleted
}

// revealExport shows the saved bundle in the file manager.
func (m *Model) revealExport() {
	destination := m.export.destination
	if m.export.phase != exportCompleted || destination == "" || m.opts.Reveal == nil {
		return
	}
	// The file manager can take a while to answer, so the window thread does not wait.
	m.spawn(func() {
		if err := m.opts.Reveal(destination); err != nil {
			m.post(func() { m.report(err) })
		}
	})
}

// exportFailure reports a failed stage and shows the failure in the dialog.
func (m *Model) exportFailure(stage string, err error) {
	m.emitExportFailure(stage, err)
	m.export.phase, m.export.failedStage = exportFailed, stage
}

func (m *Model) emitExportFailure(stage string, err error) {
	fields := ErrorFields(err)
	fields["stage"] = stage
	m.opts.Source.Emit(core.LevelError, exportFailedEvent, "", fields)
}

// claimStaging marks a staging directory as held by the calling task, so closing the window
// leaves it to that task. It returns false once the window has closed.
func (m *Model) claimStaging(root string) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.closed {
		return false
	}
	if m.staging == nil {
		m.staging = map[string]bool{}
	}
	m.staging[root] = true
	return true
}

// releaseStaging ends a task's hold on a staging directory and says whether the window has
// closed meanwhile, in which case the task must remove it.
func (m *Model) releaseStaging(root string) (closed bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, ok := m.staging[root]; ok {
		m.staging[root] = false
	}
	return m.closed
}

// removeStaging removes a staging directory on its own goroutine.
func (m *Model) removeStaging(root string) {
	m.spawn(func() { m.removeStagingNow(root) })
}

// removeStagingNow removes a staging directory and forgets it. A directory that is already
// gone is not a failure.
func (m *Model) removeStagingNow(root string) {
	err := os.RemoveAll(root)
	m.mu.Lock()
	delete(m.staging, root)
	m.mu.Unlock()
	if err != nil && !errors.Is(err, fs.ErrNotExist) {
		m.emitExportFailure(stageCleanup, err)
	}
}

// removeUnheldStaging removes, when the window closes, every staging directory no task holds.
func (m *Model) removeUnheldStaging() {
	m.mu.Lock()
	var roots []string
	for root, held := range m.staging {
		if !held {
			roots = append(roots, root)
		}
	}
	m.mu.Unlock()
	for _, root := range roots {
		m.removeStaging(root)
	}
}

// bundlePath is where a file of the bundle goes under content. A path that would leave the
// folder is an error: the paths come from the kernel, but the disk is the window's.
func bundlePath(content, relative string) (string, error) {
	local := filepath.FromSlash(relative)
	if !filepath.IsLocal(local) {
		return "", &fs.PathError{Op: "stage", Path: relative, Err: fs.ErrInvalid}
	}
	return filepath.Join(content, local), nil
}

// writeAtomic replaces path with data: a reader sees the old file or the whole new one.
func writeAtomic(path string, data []byte) error {
	dir, name := filepath.Split(path)
	file, err := os.CreateTemp(dir, "."+name+".*.tmp")
	if err != nil {
		return err
	}
	temp := file.Name()
	defer os.Remove(temp)
	if _, err := file.Write(data); err != nil {
		file.Close()
		return err
	}
	if err := file.Close(); err != nil {
		return err
	}
	return os.Rename(temp, path)
}

// zipFolder packs folder into a zip archive at destination, with the folder itself at the
// archive's root. The archive is written next to destination first and renamed into place,
// so destination is either the old file or the complete archive.
func zipFolder(folder, destination string) error {
	parent := filepath.Dir(folder)
	temp := filepath.Join(filepath.Dir(destination), ".lithe-diagnostics-"+newID()+".zip")
	file, err := os.OpenFile(temp, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return err
	}
	defer os.Remove(temp)
	archive := zip.NewWriter(file)
	err = filepath.WalkDir(folder, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		relative, err := filepath.Rel(parent, path)
		if err != nil {
			return err
		}
		name := filepath.ToSlash(relative)
		info, err := entry.Info()
		if err != nil {
			return err
		}
		header, err := zip.FileInfoHeader(info)
		if err != nil {
			return err
		}
		if entry.IsDir() {
			header.Name, header.Method = name+"/", zip.Store
			_, err = archive.CreateHeader(header)
			return err
		}
		if !entry.Type().IsRegular() {
			return nil
		}
		header.Name, header.Method = name, zip.Deflate
		writer, err := archive.CreateHeader(header)
		if err != nil {
			return err
		}
		source, err := os.Open(path)
		if err != nil {
			return err
		}
		defer source.Close()
		_, err = io.Copy(writer, source)
		return err
	})
	if closeErr := archive.Close(); err == nil {
		err = closeErr
	}
	if closeErr := file.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		return err
	}
	return os.Rename(temp, destination)
}

// fileCount is how many files the staged bundle holds: its manifest's and the manifest.
func (e *exportState) fileCount() int {
	if e.manifest == nil {
		return 0
	}
	return len(e.manifest.Files) + 1
}
