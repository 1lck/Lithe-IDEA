package workbench

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"path/filepath"
	"slices"
	"sync"

	"github.com/1lck/Lithe-IDEA/desktop/internal/configfile"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/rope"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/syntax"
	"github.com/1lck/Lithe-IDEA/desktop/internal/settingswindow"
)

const (
	globalFileTypeMappingsPath  = "file-type-mappings.json"
	projectFileTypeMappingsPath = ".lithe/file-type-mappings.json"
	maxFileTypeMappingsBytes    = 256 << 10
)

type fileTypeMappingsFile struct {
	SchemaVersion int                    `json:"schemaVersion"`
	Mappings      []core.FileTypeMapping `json:"mappings"`
}

type projectFileTypeMappings struct {
	root  string
	ready chan struct{}
	once  sync.Once
	mu    sync.RWMutex
	rules []core.FileTypeMapping
}

func newProjectFileTypeMappings(root string) *projectFileTypeMappings {
	return &projectFileTypeMappings{
		root:  root,
		ready: make(chan struct{}),
	}
}

func (m *projectFileTypeMappings) finish() {
	if m == nil {
		return
	}
	m.once.Do(func() {
		close(m.ready)
	})
}

func (m *projectFileTypeMappings) set(rules []core.FileTypeMapping) {
	if m == nil {
		return
	}
	m.mu.Lock()
	m.rules = slices.Clone(rules)
	m.mu.Unlock()
}

func (m *projectFileTypeMappings) snapshot() []core.FileTypeMapping {
	if m == nil {
		return nil
	}
	m.mu.RLock()
	defer m.mu.RUnlock()
	return slices.Clone(m.rules)
}

func (a *App) setGlobalFileTypeMappings(rules []core.FileTypeMapping) {
	cloned := slices.Clone(rules)
	a.globalFileTypeMappings.Store(&cloned)
}

func (a *App) globalFileTypeMappingsSnapshot() []core.FileTypeMapping {
	if ptr := a.globalFileTypeMappings.Load(); ptr != nil {
		return slices.Clone(*ptr)
	}
	return nil
}

func (a *App) loadGlobalFileTypeMappings() {
	if a.store == nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), kernelCallTimeout)
	defer cancel()
	snap, err := configfile.Capture(ctx, a.store.Dir(), globalFileTypeMappingsPath, maxFileTypeMappingsBytes)
	if err != nil {
		a.backgroundFailed("file_type_mappings", err)
		return
	}
	rules, err := decodeFileTypeMappingsSnapshot(snap)
	if err != nil {
		a.backgroundFailed("file_type_mappings", err)
		return
	}
	norm, err := core.NewClient().NormalizeFileTypeMappings(ctx, rules, nil, nil)
	if err != nil {
		a.backgroundFailed("file_type_mappings", err)
		return
	}
	a.setGlobalFileTypeMappings(norm.Global)
}

func (a *App) loadProjectFileTypeMappings(p *project, m *projectFileTypeMappings) {
	if p == nil || m == nil || p.remote != nil || p.standalone {
		m.finish()
		return
	}
	a.background(p, kernelCallTimeout, func(ctx context.Context) func(*App) {
		defer m.finish()
		snap, err := configfile.Capture(ctx, m.root, projectFileTypeMappingsPath, maxFileTypeMappingsBytes)
		if err != nil {
			if ctx.Err() == nil {
				return func(a *App) { a.backgroundFailed("file_type_mappings", err) }
			}
			return nil
		}
		rules, err := decodeFileTypeMappingsSnapshot(snap)
		if err != nil {
			return func(a *App) { a.backgroundFailed("file_type_mappings", err) }
		}
		norm, err := core.NewClient().NormalizeFileTypeMappings(ctx, nil, rules, nil)
		if err != nil {
			if ctx.Err() == nil {
				return func(a *App) { a.backgroundFailed("file_type_mappings", err) }
			}
			return nil
		}
		m.set(norm.Project)
		return nil
	})
}

// resolvePathLanguage resolves a path across project user rules, global user rules,
// plugin-declared languages, Core's built-in mappings, and bundled languages.
func (a *App) resolvePathLanguage(ctx context.Context, registry *syntax.Registry, path string) (string, *syntax.Syntax, bool) {
	global := a.globalFileTypeMappingsSnapshot()
	var root string
	var proj []core.FileTypeMapping
	if pm := a.activeProjectMappings.Load(); pm != nil {
		select {
		case <-pm.ready:
		case <-ctx.Done():
			return "", nil, false
		}
		root = pm.root
		proj = pm.snapshot()
	}

	matchPath := path
	if root != "" {
		if rel, ok := projectRelative(root, path); ok {
			matchPath = rel
		} else {
			matchPath = filepath.Base(path)
		}
	}

	resolved, err := core.NewClient().ResolveFileTypeMapping(ctx, matchPath, global, proj, true)
	if err != nil && ctx.Err() == nil {
		a.backgroundFailedIn(ctx, "file_type_mappings", err)
	}
	if err == nil && (resolved.Source == "project" || resolved.Source == "global") {
		return resolved.LanguageID, registry.SyntaxForLanguage(resolved.LanguageID, path), true
	}
	if language, ok := registry.PluginForPath(path); ok {
		return language.ID, registry.SyntaxForLanguage(language.ID, path), true
	}
	if err == nil && resolved.Source == "builtin" {
		return resolved.LanguageID, registry.SyntaxForLanguage(resolved.LanguageID, path), true
	}
	if language, ok := registry.BundledForPath(path); ok {
		return language.ID, registry.SyntaxForLanguage(language.ID, path), true
	}
	return "", nil, false
}

// refreshOpenDocumentLanguages re-resolves syntax, language IDs, and diff grammars for open
// documents after file type mappings change.
func (a *App) refreshOpenDocumentLanguages(p *project) {
	if p == nil {
		return
	}
	type docInput struct {
		id       int
		path     string
		snapshot rope.Rope
	}
	var docs []docInput
	for _, d := range p.docs.list {
		if d.virtual || d.scratch || d.path == "" {
			continue
		}
		docs = append(docs, docInput{id: d.id, path: d.path, snapshot: d.view.TextSnapshot()})
	}
	for _, t := range p.diffs.list {
		t.grammarPath = ""
		a.loadDiffGrammar(p, t)
	}
	if len(docs) == 0 {
		return
	}
	registry := a.syntaxRegistry()
	a.background(p, kernelCallTimeout, func(ctx context.Context) func(*App) {
		type docResolved struct {
			id         int
			languageID string
			grammar    *syntax.Syntax
		}
		results := make([]docResolved, 0, len(docs))
		for _, doc := range docs {
			langID, grammar := a.resolveDocumentLanguage(ctx, registry, doc.path, doc.snapshot)
			results = append(results, docResolved{id: doc.id, languageID: langID, grammar: grammar})
		}
		return func(a *App) {
			if a.project != p {
				return
			}
			for _, res := range results {
				d := p.docs.find(res.id)
				if d == nil {
					continue
				}
				langChanged := d.languageID != res.languageID
				if langChanged && d.sync.opened {
					a.closeDocumentInSession(p, d)
					d.sync.reset()
				}
				d.languageID = res.languageID
				d.grammar = res.grammar
				d.view.SetSyntax(res.grammar)
				if d.lens != nil {
					d.lens.SetSyntax(res.grammar)
				}
				if langChanged && res.languageID != "" && p.remote == nil && !d.virtual && !d.scratch {
					a.startPluginServer(res.languageID)
					a.startDocumentSync(p, d)
				}
			}
		}
	})
}

type appFileTypeMappings struct{ app *App }

func (s appFileTypeMappings) activeLocalProject() *project {
	if s.app == nil {
		return nil
	}
	p := s.app.project
	if p == nil || p.remote != nil || p.standalone {
		return nil
	}
	return p
}

func (s appFileTypeMappings) Load(ctx context.Context) (settingswindow.FileTypeMappingsSnapshot, error) {
	type contextInfo struct {
		storeDir      string
		hasWorkspace  bool
		workspaceRoot string
		knownIDs      []string
	}
	infoCh := make(chan contextInfo, 1)
	s.app.post(func(a *App) {
		var storeDir string
		if a.store != nil {
			storeDir = a.store.Dir()
		}
		p := s.activeLocalProject()
		var root string
		if p != nil {
			root = p.root
		}
		infoCh <- contextInfo{
			storeDir:      storeDir,
			hasWorkspace:  p != nil,
			workspaceRoot: root,
			knownIDs:      a.syntaxRegistry().KnownLanguageIDs(),
		}
	})
	var info contextInfo
	select {
	case info = <-infoCh:
	case <-ctx.Done():
		return settingswindow.FileTypeMappingsSnapshot{}, ctx.Err()
	}

	var out settingswindow.FileTypeMappingsSnapshot
	out.HasWorkspace = info.hasWorkspace
	out.WorkspaceRoot = info.workspaceRoot
	out.KnownLanguageIDs = info.knownIDs

	var globalRaw []core.FileTypeMapping
	if info.storeDir != "" {
		snap, err := configfile.Capture(ctx, info.storeDir, globalFileTypeMappingsPath, maxFileTypeMappingsBytes)
		if err != nil {
			return settingswindow.FileTypeMappingsSnapshot{}, err
		}
		out.GlobalSource = snap
		out.GlobalConfigPath = snap.Path()
		out.GlobalFingerprint = snapshotFingerprint(snap)
		globalRaw, err = decodeFileTypeMappingsSnapshot(snap)
		if err != nil {
			return settingswindow.FileTypeMappingsSnapshot{}, err
		}
	}

	var projectRaw []core.FileTypeMapping
	if info.hasWorkspace {
		snap, err := configfile.Capture(ctx, info.workspaceRoot, projectFileTypeMappingsPath, maxFileTypeMappingsBytes)
		if err != nil {
			return settingswindow.FileTypeMappingsSnapshot{}, err
		}
		out.ProjectSource = snap
		out.ProjectConfigPath = snap.Path()
		out.ProjectFingerprint = snapshotFingerprint(snap)
		projectRaw, err = decodeFileTypeMappingsSnapshot(snap)
		if err != nil {
			return settingswindow.FileTypeMappingsSnapshot{}, err
		}
	}

	norm, err := core.NewClient().NormalizeFileTypeMappings(ctx, globalRaw, projectRaw, nil)
	if err != nil {
		return settingswindow.FileTypeMappingsSnapshot{}, err
	}
	out.Builtins = norm.Builtins
	out.Global = norm.Global
	out.Project = norm.Project
	return out, nil
}

func (s appFileTypeMappings) Save(ctx context.Context, base, next settingswindow.FileTypeMappingsSnapshot) (settingswindow.FileTypeMappingsSaveResult, error) {
	ctx = s.app.performedIn(ctx, "settings.fileTypeMappings.save", surfaceButton)
	norm, err := core.NewClient().NormalizeFileTypeMappings(ctx, next.Global, next.Project, base.KnownLanguageIDs)
	if err != nil {
		if !errors.Is(err, context.Canceled) {
			s.app.operationFailedIn(ctx, "file_type_mappings", err)
		}
		return settingswindow.FileTypeMappingsSaveResult{}, err
	}
	if len(norm.Issues) > 0 {
		s.app.operationRejectedIn(ctx, "file_type_mappings", "validation_failed")
		return settingswindow.FileTypeMappingsSaveResult{Issues: norm.Issues}, nil
	}

	if err := publishMappingsScope(ctx, base.GlobalSource, base.Global, norm.Global); err != nil {
		if !errors.Is(err, context.Canceled) {
			s.app.operationFailedIn(ctx, "file_type_mappings", err)
		}
		return settingswindow.FileTypeMappingsSaveResult{}, err
	}
	if base.HasWorkspace {
		if err := publishMappingsScope(ctx, base.ProjectSource, base.Project, norm.Project); err != nil {
			if !errors.Is(err, context.Canceled) {
				s.app.operationFailedIn(ctx, "file_type_mappings", err)
			}
			return settingswindow.FileTypeMappingsSaveResult{}, err
		}
	}

	reloaded, err := s.Load(ctx)
	if err != nil {
		if !errors.Is(err, context.Canceled) {
			s.app.operationFailedIn(ctx, "file_type_mappings", err)
		}
		return settingswindow.FileTypeMappingsSaveResult{}, err
	}

	applied := make(chan struct{})
	s.app.post(func(a *App) {
		defer close(applied)
		tabs := a.sessions.everyOne()
		if len(tabs) == 0 {
			tabs = []*App{a}
		}
		for _, tab := range tabs {
			tab.setGlobalFileTypeMappings(reloaded.Global)
			if p := tab.project; p != nil {
				if base.HasWorkspace && p.root == base.WorkspaceRoot && p.fileTypeMappings != nil {
					p.fileTypeMappings.set(reloaded.Project)
				}
				tab.refreshOpenDocumentLanguages(p)
			}
		}
	})
	select {
	case <-applied:
	case <-ctx.Done():
		return settingswindow.FileTypeMappingsSaveResult{}, ctx.Err()
	}
	return settingswindow.FileTypeMappingsSaveResult{Snapshot: reloaded}, nil
}

func publishMappingsScope(ctx context.Context, source configfile.Snapshot, previous, next []core.FileTypeMapping) error {
	if slices.Equal(previous, next) {
		return nil
	}
	if len(next) == 0 {
		if source.Exists() {
			_, err := source.Remove(ctx, nil)
			return err
		}
		return source.Verify(ctx)
	}
	encoded, err := encodeFileTypeMappingsFile(next)
	if err != nil {
		return err
	}
	_, err = source.Replace(ctx, encoded, nil)
	return err
}

func decodeFileTypeMappingsSnapshot(snap configfile.Snapshot) ([]core.FileTypeMapping, error) {
	if !snap.Exists() {
		return nil, nil
	}
	raw := bytes.TrimSpace(snap.Bytes())
	if !bytes.HasPrefix(raw, []byte("{")) {
		return nil, errors.New("invalid file type mappings document")
	}
	var doc fileTypeMappingsFile
	if err := json.Unmarshal(raw, &doc); err != nil {
		return nil, err
	}
	return doc.Mappings, nil
}

func encodeFileTypeMappingsFile(mappings []core.FileTypeMapping) ([]byte, error) {
	if mappings == nil {
		mappings = []core.FileTypeMapping{}
	}
	data, err := json.MarshalIndent(fileTypeMappingsFile{
		SchemaVersion: 1,
		Mappings:      mappings,
	}, "", "  ")
	if err != nil {
		return nil, err
	}
	return append(data, '\n'), nil
}

func snapshotFingerprint(snap configfile.Snapshot) string {
	if !snap.Exists() {
		return "missing"
	}
	sum := sha256.Sum256(snap.Bytes())
	return hex.EncodeToString(sum[:])
}
