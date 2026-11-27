package workbench

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
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
	unreadable          bool // saved rules could not be decoded; do not replace their file
	status              core.IndexingStatus
	presentation        map[string]core.ResolvedDirectoryEntry
	customIconCache     map[string]gfx.Icon
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
	ResolveDirectoryPresentation(ctx context.Context, rules, sharedRules json.RawMessage, gitExcluded []string, caseInsensitive bool, paths []string) (core.DirectoryPresentationResult, error)
}

// directoryColorSwatch is one preset color offered in the quick color menu and settings.
type directoryColorSwatch struct {
	label string
	hex   string
}

func directoryColorSwatchesFor(language i18n.Language) []directoryColorSwatch {
	return []directoryColorSwatch{
		{label: i18n.Shared(language, "desktop.directoryMarks.color.blue"), hex: "#4e8df5"},
		{label: i18n.Shared(language, "desktop.directoryMarks.color.green"), hex: "#57ab5a"},
		{label: i18n.Shared(language, "desktop.directoryMarks.color.amber"), hex: "#e09b3d"},
		{label: i18n.Shared(language, "desktop.directoryMarks.color.purple"), hex: "#9f7aea"},
		{label: i18n.Shared(language, "desktop.directoryMarks.color.teal"), hex: "#38b2ac"},
		{label: i18n.Shared(language, "desktop.directoryMarks.color.rose"), hex: "#e56b6f"},
		{label: i18n.Shared(language, "desktop.directoryMarks.color.slate"), hex: "#8b949e"},
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
	lang := a.language()
	a.background(p, kernelCallTimeout, func(ctx context.Context) func(*App) {
		var readFailure error
		if !loaded {
			name := directoryRulesName(root)
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
		policy := core.IndexingPolicyOf(rules, gitIgnore)
		if sharedEnabled && len(sharedRules) > 0 {
			sharedPolicy := core.IndexingPolicyOf(sharedRules, false)
			for _, dir := range sharedPolicy.ManualExcludedDirectories {
				if !slices.Contains(policy.ManualExcludedDirectories, dir) && !slices.Contains(policy.IncludedDirectories, dir) {
					policy.ManualExcludedDirectories = append(policy.ManualExcludedDirectories, dir)
				}
			}
		}
		status, err := kernel.ConfigureIndexing(ctx, root, owner, policy, refresh)
		return func(a *App) {
			if ix.generation != generation {
				return
			}
			if !loaded && !ix.loaded {
				ix.rules, ix.gitIgnore, ix.loaded = rules, gitIgnore, true
				ix.sharedConfigEnabled, ix.sharedConfigPath, ix.sharedRules = sharedEnabled, sharedPath, sharedRules
				ix.hideBgTint, ix.hideTags, ix.customTypesSeeded = hideBgTint, hideTags, seeded
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
			if status.GitIgnoreFailed && !ix.warned {
				ix.warned = true
				a.notifyInfo(i18n.Shared(a.language(), "indexing.gitFailed"))
			}
			// Search results cached under the previous policy are stale.
			a.searchView.reset()
			a.refreshDirectoryPresentation(p)
		}
	})
}

// refreshDirectoryPresentation asks Core for the flat presentation map of all currently loaded
// tree nodes so drawTreeContent can style each row in O(1) without per-frame work.
func (a *App) refreshDirectoryPresentation(p *project) {
	if p == nil || p.remote != nil {
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
	a.background(p, kernelCallTimeout, func(ctx context.Context) func(*App) {
		res, err := meta.ResolveDirectoryPresentation(ctx, rules, shared, gitExcluded, false, paths)
		return func(a *App) {
			if ix.presGeneration != gen {
				return
			}
			if err != nil {
				a.operationFailed("workspace_directory_presentation", err)
				return
			}
			ix.presentation = res.Entries
			if p.tree.wake != nil {
				p.tree.wake()
			}
		}
	})
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
	joined := filepath.Clean(filepath.Join(root, filepath.FromSlash(cleaned)))
	rel, err := filepath.Rel(root, joined)
	if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return "", errors.New("shared config path escapes workspace root")
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
	a.background(p, kernelCallTimeout, func(ctx context.Context) func(*App) {
		changed, next, err := reduce(ctx, rules)
		if err == nil && changed {
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
		}
		return func(a *App) {
			if err != nil {
				a.notifyError(i18n.SharedFormat(a.language(), "desktop.files.excludeFailed", map[string]string{"reason": reviewReason(err)}))
				a.operationFailed("workspace_exclude", err)
				return
			}
			if !changed {
				return
			}
			p.indexing.rules, p.indexing.gitIgnore = next, gitIgnore
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
