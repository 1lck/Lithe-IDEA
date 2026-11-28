package workbench

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"maps"
	"os"
	"path"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync/atomic"

	"github.com/1lck/Lithe-IDEA/desktop/internal/atomicfile"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/fileicons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/gfx"
)

// This file manages workspace directory roles, custom folder types, color overrides and
// indexing exclusions (matrix id workspace-indexing-exclusions). Every rule transition goes
// through Core's workspace.reduceDirectoryAction, presentation merging goes through
// workspace.resolveDirectoryPresentation, and indexing obeys workspace.configureIndexing.

const defaultSharedDirectoryRulesPath = ".lithe/directories.json"

// directoryRulesFile is the stored local rules and preferences of one project folder.
type directoryRulesFile struct {
	Root  string          `json:"root"`
	Rules json.RawMessage `json:"rules"`
	// GitIgnoreDisabled keeps the folders Git ignores in the indexes; by default they are left out.
	GitIgnoreDisabled bool `json:"gitIgnoreDisabled,omitempty"`
	// SharedConfigEnabled loads optional team-shared directory rules from SharedConfigPath.
	SharedConfigEnabled bool   `json:"sharedConfigEnabled,omitempty"`
	SharedConfigPath    string `json:"sharedConfigPath,omitempty"`
	// HideBgTint and HideTags default to false so background tinting and tags show out of the box.
	HideBgTint bool `json:"hideBgTint,omitempty"`
	HideTags   bool `json:"hideTags,omitempty"`
	// CustomTypesSeeded records that default starter custom types were already offered once,
	// so deleting them stays deleted across restarts.
	CustomTypesSeeded bool `json:"customTypesSeeded,omitempty"`
}

// sharedDirectoryRulesFile is the optional workspace-relative team-shared file (.lithe/directories.json).
type sharedDirectoryRulesFile struct {
	SchemaVersion int             `json:"schemaVersion"`
	Rules         json.RawMessage `json:"rules"`
}

// projectIndexing is the directory metadata and indexing policy a project installed in Core.
type projectIndexing struct {
	owner               string
	rules               json.RawMessage
	sharedRules         json.RawMessage
	sharedConfigEnabled bool
	sharedConfigPath    string
	hideBgTint          bool
	hideTags            bool
	customTypesSeeded   bool
	gitIgnore           bool
	loaded              bool
	unreadable          bool   // saved rules could not be decoded; do not replace their file
	configFingerprint   string // SHA-256 hex of private rules file when last loaded or saved ("missing" if absent)
	status              core.IndexingStatus
	presentation        map[string]core.ResolvedDirectoryEntry
	customIconCache     map[string]gfx.Icon
	pluginTypesByKey    map[string][]core.PluginDirectoryType
	pluginMarksByKey    map[string][]core.PluginDirectoryMark
	// policyExcluded is the set of folders the installed indexing policy excludes; nil until a
	// policy is installed. globRequeued holds the glob-matched folders that asked for a new
	// policy no installation has covered yet, so one the directory walk cannot reach asks once.
	policyExcluded map[string]struct{}
	globRequeued   map[string]struct{}
	// generation rejects an installation a newer one replaced; presGeneration does the same for presentation.
	generation     uint64
	presGeneration uint64
	warned         bool
}

// indexingKernel is the part of Core directory metadata and exclusions use.
type indexingKernel interface {
	ExcludeDirectory(ctx context.Context, path string, caseInsensitive bool, rules json.RawMessage) (bool, json.RawMessage, error)
	CancelDirectoryExclusion(ctx context.Context, path string, caseInsensitive bool, rules json.RawMessage) (bool, json.RawMessage, error)
	ConfigureIndexing(ctx context.Context, root, owner string, policy core.IndexingPolicy, refresh bool) (core.IndexingStatus, error)
	ReleaseIndexing(ctx context.Context, root, owner string, revision uint64) (bool, error)
}

// directoryMetaKernel is the extended directory metadata surface of Core.
type directoryMetaKernel interface {
	SetDirectoryRole(ctx context.Context, path, role string, caseInsensitive bool, rules json.RawMessage) (bool, json.RawMessage, error)
	ClearDirectoryMark(ctx context.Context, path string, caseInsensitive bool, rules json.RawMessage) (bool, json.RawMessage, error)
	SetDirectoryColor(ctx context.Context, path, color string, caseInsensitive bool, rules json.RawMessage) (bool, json.RawMessage, error)
	UpsertCustomDirectoryType(ctx context.Context, dirType core.CustomDirectoryType, rules json.RawMessage) (bool, json.RawMessage, error)
	DeleteCustomDirectoryType(ctx context.Context, id string, rules json.RawMessage) (bool, json.RawMessage, error)
	UpsertCustomDirectoryIcon(ctx context.Context, dirIcon core.CustomDirectoryIcon, rules json.RawMessage) (bool, json.RawMessage, error)
	DeleteCustomDirectoryIcon(ctx context.Context, id string, rules json.RawMessage) (bool, json.RawMessage, error)
	RelocateDirectoryRules(ctx context.Context, source, destination string, caseInsensitive bool, rules json.RawMessage) (json.RawMessage, error)
	ResolveDirectoryPresentation(ctx context.Context, rules, sharedRules json.RawMessage, pluginTypes []core.PluginDirectoryType, pluginMarks []core.PluginDirectoryMark, gitExcluded []string, caseInsensitive bool, paths []string) (core.DirectoryPresentationResult, error)
}

// directoryColorSwatch is one preset color offered in the quick color menu and settings.
type directoryColorSwatch struct {
	label string
	hex   string
}

func directoryColorSwatchesFor(language i18n.Language) []directoryColorSwatch {
	return []directoryColorSwatch{
		{label: i18n.Shared(language, "desktop.directoryMarks.color.blue"), hex: "#3b82f6"},
		{label: i18n.Shared(language, "desktop.directoryMarks.color.green"), hex: "#2ea043"},
		{label: i18n.Shared(language, "desktop.directoryMarks.color.amber"), hex: "#d97706"},
		{label: i18n.Shared(language, "desktop.directoryMarks.color.purple"), hex: "#8b5cf6"},
		{label: i18n.Shared(language, "desktop.directoryMarks.color.teal"), hex: "#0d9488"},
		{label: i18n.Shared(language, "desktop.directoryMarks.color.rose"), hex: "#e11d48"},
		{label: i18n.Shared(language, "desktop.directoryMarks.color.slate"), hex: "#64748b"},
	}
}

// indexingOwners numbers the leases of this process.
var indexingOwners atomic.Uint64

// installIndexing reads the project's stored rules the first time and installs the policy they
// make; refresh retires what Core had cached under the previous one.
func (a *App) installIndexing(p *project, refresh bool) {
	kernel, ok := a.kernel.(indexingKernel)
	if !ok || a.store == nil {
		return
	}
	ix := &p.indexing
	if ix.owner == "" {
		ix.owner = fmt.Sprintf("viva-%d-%d", os.Getpid(), indexingOwners.Add(1))
	}
	ix.generation++
	generation, root, owner, s := ix.generation, p.root, ix.owner, a.store
	loaded, rules, gitIgnore := ix.loaded, ix.rules, ix.gitIgnore
	sharedEnabled, sharedPath, sharedRules := ix.sharedConfigEnabled, ix.sharedConfigPath, ix.sharedRules
	hideBgTint, hideTags, seeded := ix.hideBgTint, ix.hideTags, ix.customTypesSeeded
	pluginTypes := p.pluginDirectoryTypes()
	pluginMarks := p.pluginDirectoryMarks()
	lang := a.language()
	a.background(p, kernelCallTimeout, func(ctx context.Context) func(*App) {
		var readFailure error
		var loadedFingerprint string
		if !loaded {
			name := directoryRulesName(root)
			if fp, fperr := directoryRulesFingerprint(s.Dir(), root); fperr == nil {
				loadedFingerprint = fp
			}
			var stored directoryRulesFile
			found, err := s.Load(name, &stored)
			if err == nil && found {
				// A newer build may have saved a known field in a different shape.
				// Store preserves it, but applying an edit could discard the user's rules.
				err = s.Unread(name)
			}
			if err == nil && found {
				rules, gitIgnore = stored.Rules, !stored.GitIgnoreDisabled
				sharedEnabled = stored.SharedConfigEnabled
				sharedPath = stored.SharedConfigPath
				hideBgTint = stored.HideBgTint
				hideTags = stored.HideTags
				seeded = stored.CustomTypesSeeded
			} else {
				rules, gitIgnore = nil, true
				readFailure = err
			}
			if !seeded && readFailure == nil {
				if meta, ok := a.kernel.(directoryMetaKernel); ok {
					if len(core.ParseDirectoryRules(rules).CustomTypes) == 0 {
						if _, next, uerr := meta.UpsertCustomDirectoryType(ctx, defaultArchiveDirectoryType(lang), rules); uerr == nil {
							rules = next
						}
					}
				}
				seeded = true
			}
			if sharedPath == "" {
				sharedPath = defaultSharedDirectoryRulesPath
			}
			if sharedEnabled {
				if raw, _, serr := readSharedDirectoryRules(root, sharedPath); serr == nil {
					sharedRules = raw
				}
			}
		}
		var effectiveShared json.RawMessage
		if sharedEnabled && len(sharedRules) > 0 {
			effectiveShared = sharedRules
		}
		policy, pluginErr, policyErr := resolveEffectiveIndexingPolicy(ctx, a.kernel, root, rules, effectiveShared, pluginTypes, pluginMarks, gitIgnore)
		status, err := kernel.ConfigureIndexing(ctx, root, owner, policy, refresh)
		return func(a *App) {
			if ix.generation != generation {
				return
			}
			if pluginErr != nil {
				a.backgroundFailed("workspace_directory_plugin_layers", pluginErr)
			}
			if policyErr != nil {
				a.backgroundFailed("workspace_directory_policy", policyErr)
			}
			if !loaded && !ix.loaded {
				ix.rules, ix.gitIgnore, ix.loaded = rules, gitIgnore, true
				ix.sharedConfigEnabled, ix.sharedConfigPath, ix.sharedRules = sharedEnabled, sharedPath, sharedRules
				ix.hideBgTint, ix.hideTags, ix.customTypesSeeded = hideBgTint, hideTags, seeded
				ix.configFingerprint = loadedFingerprint
				ix.unreadable = readFailure != nil
				if readFailure != nil {
					a.storedStateFailed("directory_rules", readFailure)
				}
			}
			if err != nil {
				a.operationFailed("workspace_indexing", err)
				a.notifyError(i18n.Shared(a.language(), "indexing.configureFailed"))
				return
			}
			ix.status = status
			ix.installed(policy.ManualExcludedDirectories)
			if status.GitIgnoreFailed && !ix.warned {
				ix.warned = true
				a.notifyInfo(i18n.Shared(a.language(), "indexing.gitFailed"))
			}
			// Results found under the previous policy are stale. A plugin or a new folder can
			// install a policy at any moment, so run the search again with what the user typed
			// rather than clearing the Find in Files form; opening a project clears it already.
			if strings.TrimSpace(p.search.want.text) != "" {
				a.refreshProjectSearch(p)
			}
			a.refreshDirectoryPresentation(p)
		}
	})
}

// refreshDirectoryPresentation asks Core for the flat presentation map of all currently loaded
// tree nodes so drawTreeContent can style each row in O(1) without per-frame work.
func (a *App) refreshDirectoryPresentation(p *project) {
	if p == nil || p.remote != nil || p.ctx == nil {
		return
	}
	meta, ok := a.kernel.(directoryMetaKernel)
	if !ok {
		return
	}
	ix := &p.indexing
	paths := make([]string, 0, len(p.tree.rows))
	for _, n := range p.tree.rows {
		if n != nil && n.path != "" {
			paths = append(paths, n.path)
		}
	}
	if len(paths) == 0 {
		return
	}
	gitExcluded := make([]string, 0, len(ix.status.ExcludedDirectories))
	for dir := range ix.status.ExcludedDirectories {
		gitExcluded = append(gitExcluded, dir)
	}
	ix.presGeneration++
	gen := ix.presGeneration
	rules := ix.rules
	var shared json.RawMessage
	if ix.sharedConfigEnabled {
		shared = ix.sharedRules
	}
	pluginTypes := p.pluginDirectoryTypes()
	pluginMarks := p.pluginDirectoryMarks()
	a.background(p, kernelCallTimeout, func(ctx context.Context) func(*App) {
		res, pluginErr, err := resolveDirectoryLayers(ctx, meta, rules, shared, pluginTypes, pluginMarks, gitExcluded, paths)
		return func(a *App) {
			if ix.presGeneration != gen {
				return
			}
			if pluginErr != nil {
				a.backgroundFailed("workspace_directory_plugin_layers", pluginErr)
			}
			if err != nil {
				a.operationFailed("workspace_directory_presentation", err)
				return
			}
			ix.presentation = res.Entries
			if p.tree.wake != nil {
				p.tree.wake()
			}
			if ix.staleGlobExclusions(res.Entries) {
				a.installIndexing(p, true)
			}
		}
	})
}

// installed records the folders an indexing policy just installed excludes. A folder the
// policy now covers may ask again later, after it is renamed away and back; one it still does
// not cover, such as a folder past the directory walk's limit, keeps its single request so it
// cannot install the policy over and over.
func (ix *projectIndexing) installed(excluded []string) {
	ix.policyExcluded = make(map[string]struct{}, len(excluded))
	for _, dir := range excluded {
		ix.policyExcluded[dir] = struct{}{}
		delete(ix.globRequeued, dir)
	}
}

// staleGlobExclusions reports whether Core matches a shown folder to an excluding glob that
// the installed indexing policy does not exclude yet. Globs reach the policy through a walk
// of the folders present when it was installed, so a folder created or renamed since then
// would otherwise stay searchable until the project reopens. Each folder asks once until a
// policy covers it.
func (ix *projectIndexing) staleGlobExclusions(entries map[string]core.ResolvedDirectoryEntry) bool {
	if ix.policyExcluded == nil {
		return false
	}
	stale := false
	for dir, entry := range entries {
		if entry.Source != "glob" || !entry.Excluded {
			continue
		}
		if _, ok := ix.policyExcluded[dir]; ok {
			continue
		}
		if _, ok := ix.globRequeued[dir]; ok {
			continue
		}
		if ix.globRequeued == nil {
			ix.globRequeued = make(map[string]struct{})
		}
		ix.globRequeued[dir] = struct{}{}
		stale = true
	}
	return stale
}

// releaseIndexing gives up the project's lease as it closes. It runs past the project's end.
func (a *App) releaseIndexing(p *project) {
	kernel, ok := a.kernel.(indexingKernel)
	ix := &p.indexing
	if !ok || ix.owner == "" {
		return
	}
	ix.generation++
	root, owner, revision := p.root, ix.owner, ix.status.Revision
	parent := a.operationContext(context.Background())
	go func() {
		ctx, cancel := context.WithTimeout(parent, kernelCallTimeout)
		defer cancel()
		if _, err := kernel.ReleaseIndexing(ctx, root, owner, revision); err != nil {
			a.emitIn(ctx, backgroundFailedLevel, backgroundFailedEvent, operationFailedFields("workspace_indexing_release", err))
		}
	}()
}

// directoryExcluded reports whether the folder at rel is known to be left out of search, and
// whether by hand.
func (p *project) directoryExcluded(rel string) bool {
	cleaned := path.Clean(rel)
	if entry, ok := p.indexing.presentation[cleaned]; ok && entry.Excluded {
		return true
	}
	_, ok := p.indexing.status.ExcludedDirectories[cleaned]
	return ok || slices.Contains(core.IndexingPolicyOf(p.indexing.rules, false).ManualExcludedDirectories, cleaned)
}

// directoryRulesName is the store name of the rules of the project folder root.
func directoryRulesName(root string) string {
	sum := sha256.Sum256([]byte(root))
	return "workspace-directory-rules-" + hex.EncodeToString(sum[:8]) + ".json"
}

// directoryRulesFingerprint returns the SHA-256 hex digest of the stored private directory
// rules file on disk, or "missing" when the file does not exist yet.
func directoryRulesFingerprint(storeDir, root string) (string, error) {
	full := filepath.Join(storeDir, directoryRulesName(root))
	data, err := os.ReadFile(full)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return "missing", nil
		}
		return "", err
	}
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:]), nil
}

const maxGlobWalkDirs = 50_000

// pluginDirectoryTypes returns all active plugin-contributed directory types for p in
// deterministic order: by plugin and type ID, and for the same plugin and ID in two of its
// sessions or contexts, by lease key.
func (p *project) pluginDirectoryTypes() []core.PluginDirectoryType {
	if p == nil || len(p.indexing.pluginTypesByKey) == 0 {
		return nil
	}
	var out []core.PluginDirectoryType
	for _, key := range slices.Sorted(maps.Keys(p.indexing.pluginTypesByKey)) {
		out = append(out, p.indexing.pluginTypesByKey[key]...)
	}
	slices.SortStableFunc(out, func(a, b core.PluginDirectoryType) int {
		if c := strings.Compare(a.PluginID, b.PluginID); c != 0 {
			return c
		}
		return strings.Compare(a.ID, b.ID)
	})
	return out
}

// pluginDirectoryMarks returns all active plugin-contributed directory marks for p in
// deterministic order: by plugin and path, and for the same plugin and path in two of its
// sessions or contexts, by lease key.
func (p *project) pluginDirectoryMarks() []core.PluginDirectoryMark {
	if p == nil || len(p.indexing.pluginMarksByKey) == 0 {
		return nil
	}
	var out []core.PluginDirectoryMark
	for _, key := range slices.Sorted(maps.Keys(p.indexing.pluginMarksByKey)) {
		out = append(out, p.indexing.pluginMarksByKey[key]...)
	}
	slices.SortStableFunc(out, func(a, b core.PluginDirectoryMark) int {
		if c := strings.Compare(a.PluginID, b.PluginID); c != 0 {
			return c
		}
		return strings.Compare(a.Path, b.Path)
	})
	return out
}

// hasExcludingGlob reports whether any custom or plugin directory type combines
// excludeIndexing with a non-empty matchGlob pattern.
func hasExcludingGlob(rules, sharedRules json.RawMessage, pluginTypes []core.PluginDirectoryType) bool {
	for _, raw := range []json.RawMessage{rules, sharedRules} {
		if len(raw) == 0 {
			continue
		}
		for _, ct := range core.ParseDirectoryRules(raw).CustomTypes {
			if ct.ExcludeIndexing && strings.TrimSpace(ct.MatchGlob) != "" {
				return true
			}
		}
	}
	for _, pt := range pluginTypes {
		if pt.ExcludeIndexing && strings.TrimSpace(pt.MatchGlob) != "" {
			return true
		}
	}
	return false
}

// walkWorkspaceDirs collects workspace-relative directory paths under root (up to maxGlobWalkDirs)
// without following symlinks and skipping .git, so Core can evaluate glob-based exclusions.
func walkWorkspaceDirs(root string) []string {
	if root == "" {
		return nil
	}
	var dirs []string
	_ = filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if p == root {
			return nil
		}
		if d.Type()&os.ModeSymlink != 0 {
			if d.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		if !d.IsDir() {
			return nil
		}
		if d.Name() == ".git" {
			return filepath.SkipDir
		}
		rel, rerr := filepath.Rel(root, p)
		if rerr != nil || rel == "." {
			return nil
		}
		dirs = append(dirs, filepath.ToSlash(rel))
		if len(dirs) >= maxGlobWalkDirs {
			return fs.SkipAll
		}
		return nil
	})
	return dirs
}

// resolveDirectoryLayers asks Core to resolve every layer and, when that fails while plugins
// contribute, once more without the plugin layers, so what plugins registered can never take
// the user's and the team's rules away. pluginErr is the failure the plugin layers caused and
// err the failure of the answer returned.
func resolveDirectoryLayers(ctx context.Context, meta directoryMetaKernel, rules, sharedRules json.RawMessage, pluginTypes []core.PluginDirectoryType, pluginMarks []core.PluginDirectoryMark, gitExcluded, paths []string) (res core.DirectoryPresentationResult, pluginErr, err error) {
	res, err = meta.ResolveDirectoryPresentation(ctx, rules, sharedRules, pluginTypes, pluginMarks, gitExcluded, false, paths)
	if err == nil || (len(pluginTypes) == 0 && len(pluginMarks) == 0) {
		return res, nil, err
	}
	pluginErr = err
	res, err = meta.ResolveDirectoryPresentation(ctx, rules, sharedRules, nil, nil, gitExcluded, false, paths)
	return res, pluginErr, err
}

// resolveEffectiveIndexingPolicy asks Core for effective manual exclusions (honoring
// user > shared > plugin > glob precedence and includedDirectories) and falls back to
// IndexingPolicyOf when the kernel does not implement directoryMetaKernel or cannot resolve
// even without the plugin layers. pluginErr is the failure the plugin layers caused and err
// the failure that left only the local rules' exclusions.
func resolveEffectiveIndexingPolicy(ctx context.Context, k any, root string, rules, sharedRules json.RawMessage, pluginTypes []core.PluginDirectoryType, pluginMarks []core.PluginDirectoryMark, gitIgnore bool) (policy core.IndexingPolicy, pluginErr, err error) {
	policy = core.IndexingPolicyOf(rules, gitIgnore)
	meta, ok := k.(directoryMetaKernel)
	if !ok {
		return policy, nil, nil
	}
	var globCandidates []string
	if hasExcludingGlob(rules, sharedRules, pluginTypes) {
		globCandidates = walkWorkspaceDirs(root)
	}
	res, pluginErr, err := resolveDirectoryLayers(ctx, meta, rules, sharedRules, pluginTypes, pluginMarks, nil, globCandidates)
	if err != nil {
		return policy, pluginErr, err
	}
	if res.ManualExcludedDirectories == nil {
		policy.ManualExcludedDirectories = []string{}
	} else {
		policy.ManualExcludedDirectories = res.ManualExcludedDirectories
	}
	return policy, pluginErr, nil
}

// readSharedDirectoryRules reads an optional workspace-relative shared directory rules file.
func readSharedDirectoryRules(root, relPath string) (json.RawMessage, bool, error) {
	full, err := resolveWorkspaceFilePath(root, relPath)
	if err != nil {
		return nil, false, err
	}
	data, err := os.ReadFile(full)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, false, nil
		}
		return nil, false, err
	}
	var file sharedDirectoryRulesFile
	if err := json.Unmarshal(data, &file); err != nil {
		return nil, true, err
	}
	if len(file.Rules) == 0 {
		return core.EmptyDirectoryRules(), true, nil
	}
	return file.Rules, true, nil
}

// writeSharedDirectoryRules atomically writes the workspace-relative shared rules file.
func writeSharedDirectoryRules(root, relPath string, rules json.RawMessage) error {
	full, err := resolveWorkspaceFilePath(root, relPath)
	if err != nil {
		return err
	}
	if len(rules) == 0 {
		rules = core.EmptyDirectoryRules()
	}
	data, err := json.MarshalIndent(sharedDirectoryRulesFile{SchemaVersion: 1, Rules: rules}, "", "  ")
	if err != nil {
		return err
	}
	data = append(data, '\n')
	return atomicfile.Write(full, data, 0o644)
}

func resolveWorkspaceFilePath(root, relPath string) (string, error) {
	cleaned := strings.TrimSpace(relPath)
	if cleaned == "" {
		cleaned = defaultSharedDirectoryRulesPath
	}
	if filepath.IsAbs(cleaned) {
		return "", errors.New("shared config path must be workspace-relative")
	}
	realRoot, err := filepath.EvalSymlinks(root)
	if err != nil {
		return "", fmt.Errorf("resolve workspace root: %w", err)
	}
	realRoot = filepath.Clean(realRoot)
	joined := filepath.Clean(filepath.Join(realRoot, filepath.FromSlash(cleaned)))
	rel, err := filepath.Rel(realRoot, joined)
	if err != nil || rel == "." || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return "", errors.New("shared config path escapes workspace root")
	}
	// Walk every segment inside realRoot with Lstat so neither existing nor dangling symlinks
	// can redirect reads or writes outside the workspace root.
	cur := realRoot
	for _, seg := range strings.Split(rel, string(filepath.Separator)) {
		if seg == "" || seg == "." {
			continue
		}
		cur = filepath.Join(cur, seg)
		fi, lerr := os.Lstat(cur)
		if errors.Is(lerr, os.ErrNotExist) {
			break
		}
		if lerr != nil {
			return "", lerr
		}
		if fi.Mode()&os.ModeSymlink != 0 {
			return "", errors.New("shared config path must not traverse symlinks")
		}
	}
	return joined, nil
}

// excludeFromSearch leaves the folder at rel (project-relative, "/" separators) out of search;
// cancel puts it back (a folder Git ignores becomes an exception). The new rules are stored and
// installed.
func (a *App) excludeFromSearch(p *project, rel string, cancel bool) {
	kernel, ok := a.kernel.(indexingKernel)
	if !ok || a.store == nil || !p.indexing.loaded {
		return
	}
	if cancel {
		a.performed("workspace.tree.cancelExclusion", surfaceContextMenu)
	} else {
		a.performed("workspace.tree.excludeFromSearch", surfaceContextMenu)
	}
	a.changeIndexingRules(p, func(ctx context.Context, rules json.RawMessage) (bool, json.RawMessage, error) {
		if cancel {
			return kernel.CancelDirectoryExclusion(ctx, path.Clean(rel), false, rules)
		}
		return kernel.ExcludeDirectory(ctx, path.Clean(rel), false, rules)
	}, p.indexing.gitIgnore)
}

// setDirectoryRole assigns a built-in role or custom type ID to rel via Core.
func (a *App) setDirectoryRole(p *project, rel, role string) {
	meta, ok := a.kernel.(directoryMetaKernel)
	if !ok || a.store == nil || !p.indexing.loaded {
		return
	}
	a.performed("workspace.tree.setDirectoryRole", surfaceContextMenu)
	a.changeIndexingRules(p, func(ctx context.Context, rules json.RawMessage) (bool, json.RawMessage, error) {
		return meta.SetDirectoryRole(ctx, path.Clean(rel), role, false, rules)
	}, p.indexing.gitIgnore)
}

// clearDirectoryMark clears a directory's manual role and color override via Core.
func (a *App) clearDirectoryMark(p *project, rel string) {
	meta, ok := a.kernel.(directoryMetaKernel)
	if !ok || a.store == nil || !p.indexing.loaded {
		return
	}
	a.performed("workspace.tree.clearDirectoryMark", surfaceContextMenu)
	a.changeIndexingRules(p, func(ctx context.Context, rules json.RawMessage) (bool, json.RawMessage, error) {
		return meta.ClearDirectoryMark(ctx, path.Clean(rel), false, rules)
	}, p.indexing.gitIgnore)
}

// setDirectoryColor sets or clears (when hex == "") a quick color override on rel via Core.
func (a *App) setDirectoryColor(p *project, rel, hexColor string) {
	meta, ok := a.kernel.(directoryMetaKernel)
	if !ok || a.store == nil || !p.indexing.loaded {
		return
	}
	a.performed("workspace.tree.setDirectoryColor", surfaceContextMenu)
	a.changeIndexingRules(p, func(ctx context.Context, rules json.RawMessage) (bool, json.RawMessage, error) {
		return meta.SetDirectoryColor(ctx, path.Clean(rel), hexColor, false, rules)
	}, p.indexing.gitIgnore)
}

// setGitIgnoreIndexing turns the automatic exclusion of folders Git ignores on or off.
func (a *App) setGitIgnoreIndexing(p *project, on bool) {
	if !p.indexing.loaded || p.indexing.gitIgnore == on {
		return
	}
	a.performed("workspace.indexing.gitIgnore", surfaceContextMenu)
	a.changeIndexingRules(p, func(context.Context, json.RawMessage) (bool, json.RawMessage, error) {
		return true, p.indexing.rules, nil
	}, on)
}

// relocateDirectoryRules asks Core to migrate directory marks, previous roles, include
// exceptions and color overrides after a rename/move (destRel != "") or delete (destRel == "").
func (a *App) relocateDirectoryRules(p *project, sourceRel, destRel string) {
	if p == nil || p.remote != nil || p.ctx == nil || !p.indexing.loaded || p.indexing.unreadable {
		return
	}
	meta, ok := a.kernel.(directoryMetaKernel)
	if !ok || a.store == nil {
		return
	}
	state := core.ParseDirectoryRules(p.indexing.rules)
	if len(state.Marks) == 0 && len(state.Colors) == 0 && len(state.IncludedDirectories) == 0 && len(state.PreviousRoles) == 0 {
		return
	}
	src := path.Clean(sourceRel)
	dst := ""
	if destRel != "" {
		dst = path.Clean(destRel)
	}
	a.changeIndexingRules(p, func(ctx context.Context, rules json.RawMessage) (bool, json.RawMessage, error) {
		next, err := meta.RelocateDirectoryRules(ctx, src, dst, false, rules)
		if err != nil {
			return false, nil, err
		}
		return !bytes.Equal(bytes.TrimSpace(rules), bytes.TrimSpace(next)), next, nil
	}, p.indexing.gitIgnore)
}

// changeIndexingRules applies reduce to the project's rules off the window thread, stores the
// result with gitIgnore and installs it.
func (a *App) changeIndexingRules(p *project, reduce func(context.Context, json.RawMessage) (bool, json.RawMessage, error), gitIgnore bool) {
	if p.indexing.unreadable {
		// Never replace the unreadable rules with defaults after a failed load.
		// Reopen the workspace once the saved file has been repaired externally.
		a.operationRejected("workspace_exclude", "unreadable_stored_rules")
		a.notifyError(i18n.Shared(a.language(), "indexing.configureFailed"))
		return
	}
	root, s := p.root, a.store
	rules := p.indexing.rules
	if len(rules) == 0 {
		rules = core.EmptyDirectoryRules()
	}
	sharedEnabled := p.indexing.sharedConfigEnabled
	sharedPath := p.indexing.sharedConfigPath
	hideBgTint := p.indexing.hideBgTint
	hideTags := p.indexing.hideTags
	expectedFP := p.indexing.configFingerprint
	p.tree.beginWrite()
	a.background(p, kernelCallTimeout, func(ctx context.Context) func(*App) {
		changed, next, err := reduce(ctx, rules)
		var newFP string
		if err == nil && changed {
			if expectedFP != "" {
				diskFP, fperr := directoryRulesFingerprint(s.Dir(), root)
				if fperr != nil {
					err = fperr
				} else if diskFP != expectedFP {
					err = errors.New("private directory config changed on disk; reload before saving")
				}
			}
			if err == nil {
				err = s.Save(directoryRulesName(root), directoryRulesFile{
					Root:                root,
					Rules:               next,
					GitIgnoreDisabled:   !gitIgnore,
					SharedConfigEnabled: sharedEnabled,
					SharedConfigPath:    sharedPath,
					HideBgTint:          hideBgTint,
					HideTags:            hideTags,
					CustomTypesSeeded:   true,
				})
				if err == nil {
					if fp, fperr := directoryRulesFingerprint(s.Dir(), root); fperr == nil {
						newFP = fp
					}
				}
			}
		}
		return func(a *App) {
			defer p.tree.endWrite()
			if err != nil {
				a.notifyError(i18n.SharedFormat(a.language(), "desktop.files.excludeFailed", map[string]string{"reason": reviewReason(err)}))
				a.operationFailed("workspace_exclude", err)
				return
			}
			if !changed {
				return
			}
			p.indexing.rules, p.indexing.gitIgnore = next, gitIgnore
			if newFP != "" {
				p.indexing.configFingerprint = newFP
			}
			if a.project == p {
				a.installIndexing(p, true)
			}
		}
	})
}

// directoryIcon maps a Core-resolved icon identifier to a vector icon.
func directoryIcon(name string, dark bool) gfx.Icon {
	switch name {
	case "sources", "resources", "excluded", "module", "package":
		return fileicons.ForDirectoryIconName(name, dark)
	case "tests":
		return icons.Bug
	case "generated", "gear":
		return icons.Settings
	case "star":
		return icons.Sparkles
	case "book":
		return icons.FileText
	case "archive":
		return icons.Archive
	case "database":
		return icons.Server
	default:
		return fileicons.ForDirectoryIconName("folder", dark)
	}
}

// parseHexColor parses a #rrggbb string into a gfx.Color with the given alpha (0..255).
func parseHexColor(hexStr string, alpha uint8) (gfx.Color, bool) {
	if len(hexStr) != 7 || hexStr[0] != '#' {
		return gfx.Color{}, false
	}
	v, err := strconv.ParseUint(hexStr[1:], 16, 32)
	if err != nil {
		return gfx.Color{}, false
	}
	return gfx.RGBA(uint8(v>>16), uint8((v>>8)&0xff), uint8(v&0xff), float32(alpha)/255.0), true
}

// readableTreeTint returns a saturated, high-contrast tint for directory icons and names.
// On light surfaces it deepens bright colors slightly so folder names and icons never look washed out.
func readableTreeTint(hexStr string, dark bool) (gfx.Color, bool) {
	if len(hexStr) != 7 || hexStr[0] != '#' {
		return gfx.Color{}, false
	}
	v, err := strconv.ParseUint(hexStr[1:], 16, 32)
	if err != nil {
		return gfx.Color{}, false
	}
	r := uint8(v >> 16)
	g := uint8((v >> 8) & 0xff)
	b := uint8(v & 0xff)
	if !dark {
		r = uint8(float32(r) * 0.80)
		g = uint8(float32(g) * 0.80)
		b = uint8(float32(b) * 0.80)
	}
	return gfx.RGBA(r, g, b, 1), true
}

// defaultArchiveDirectoryType returns the starter removable custom directory type for
// archived / read-only folders.
func defaultArchiveDirectoryType(language i18n.Language) core.CustomDirectoryType {
	return core.CustomDirectoryType{
		ID:              "custom.archive",
		Name:            i18n.Shared(language, "desktop.directoryMarks.preset.archiveName"),
		Tag:             "archive",
		Icon:            "archive",
		Color:           "#8b949e",
		TintBg:          true,
		InheritBg:       true,
		ExcludeIndexing: true,
		ReadOnlyHint:    true,
	}
}

// directoryRoleDisplayName returns the localized label of a built-in role or custom type ID.
func directoryRoleDisplayName(language i18n.Language, role string, customTypes []core.CustomDirectoryType) string {
	for _, ct := range customTypes {
		if ct.ID == role {
			return ct.Name
		}
	}
	switch role {
	case "sources":
		return i18n.Shared(language, "desktop.directoryMarks.role.sources")
	case "tests":
		return i18n.Shared(language, "desktop.directoryMarks.role.tests")
	case "resources":
		return i18n.Shared(language, "desktop.directoryMarks.role.resources")
	case "testResources":
		return i18n.Shared(language, "desktop.directoryMarks.role.testResources")
	case "generated":
		return i18n.Shared(language, "desktop.directoryMarks.role.generated")
	case "excluded":
		return i18n.Shared(language, "desktop.directoryMarks.role.excluded")
	default:
		return role
	}
}
