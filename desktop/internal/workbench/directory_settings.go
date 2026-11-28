package workbench

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/atomicfile"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginicons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/settingswindow"
	"github.com/vivaui/viva/gfx"
)

const customDirectoryIconsDir = "directory-icons"

// openDirectoryMarksSettings opens the settings window directly on
// "Appearance & Behavior › Directory Marks & Colors".
func (a *App) openDirectoryMarksSettings() {
	a.openSettingsPage(surfaceContextMenu, settingsDirectoryMarks)
}

// directoryIconFor resolves a Core directory icon identifier to a vector icon, checking
// user-imported custom SVG icons in memory before falling back to built-in icons.
func (a *App) directoryIconFor(p *project, name string) gfx.Icon {
	if strings.HasPrefix(name, "icon.") && p != nil && a.store != nil {
		if compiled, ok := p.indexing.customIconCache[name]; ok {
			return compiled
		}
		state := core.ParseDirectoryRules(p.indexing.rules)
		for _, ci := range state.CustomIcons {
			if ci.ID == name {
				full := filepath.Join(a.store.Dir(), filepath.FromSlash(ci.Path))
				data, err := os.ReadFile(full)
				if err != nil {
					a.operationFailed("directory_custom_icon_read", err)
					break
				}
				compiled, err := pluginicons.CompileSVG(ci.Path, data)
				if err != nil {
					a.operationFailed("directory_custom_icon_compile", err)
					break
				}
				if p.indexing.customIconCache == nil {
					p.indexing.customIconCache = make(map[string]gfx.Icon)
				}
				p.indexing.customIconCache[name] = compiled
				return compiled
			}
		}
	}
	return directoryIcon(name, a.colors.Dark)
}

// appDirectoryMarks bridges the settings window's Directory Marks & Colors page to the active
// local project's Core directory rules, store files and custom SVG icon directory.
type appDirectoryMarks struct {
	app *App
}

func (s appDirectoryMarks) activeLocalProject() *project {
	if s.app == nil {
		return nil
	}
	p := s.app.project
	if p == nil || p.remote != nil {
		return nil
	}
	return p
}

func (s appDirectoryMarks) snapshotOf(p *project) settingswindow.DirectoryMarksSnapshot {
	if p == nil {
		return settingswindow.DirectoryMarksSnapshot{}
	}
	state := core.ParseDirectoryRules(p.indexing.rules)
	localPath := ""
	if s.app.store != nil {
		localPath = filepath.Join(s.app.store.Dir(), directoryRulesName(p.root))
	}
	sharedPath := p.indexing.sharedConfigPath
	if sharedPath == "" {
		sharedPath = defaultSharedDirectoryRulesPath
	}
	return settingswindow.DirectoryMarksSnapshot{
		HasWorkspace:        true,
		WorkspaceRoot:       p.root,
		ConfigFingerprint:   p.indexing.configFingerprint,
		LocalConfigPath:     localPath,
		SharedConfigEnabled: p.indexing.sharedConfigEnabled,
		SharedConfigPath:    sharedPath,
		ShowBgTint:          !p.indexing.hideBgTint,
		ShowTags:            !p.indexing.hideTags,
		GitIgnoreEnabled:    p.indexing.gitIgnore,
		CustomTypes:         state.CustomTypes,
		CustomIcons:         state.CustomIcons,
		PluginTypes:         p.pluginDirectoryTypes(),
	}
}

func (s appDirectoryMarks) Load(ctx context.Context) (settingswindow.DirectoryMarksSnapshot, error) {
	ch := make(chan settingswindow.DirectoryMarksSnapshot, 1)
	s.app.post(func(a *App) {
		ch <- s.snapshotOf(s.activeLocalProject())
	})
	select {
	case snap := <-ch:
		return snap, nil
	case <-ctx.Done():
		return settingswindow.DirectoryMarksSnapshot{}, ctx.Err()
	}
}

func (s appDirectoryMarks) Save(ctx context.Context, next settingswindow.DirectoryMarksSnapshot) (settingswindow.DirectoryMarksSnapshot, error) {
	type projectSnapshot struct {
		p           *project
		root        string
		rules       json.RawMessage
		loaded      bool
		unreadable  bool
		fingerprint string
	}
	infoCh := make(chan projectSnapshot, 1)
	s.app.post(func(a *App) {
		p := s.activeLocalProject()
		if p == nil {
			infoCh <- projectSnapshot{}
			return
		}
		infoCh <- projectSnapshot{
			p:           p,
			root:        p.root,
			rules:       p.indexing.rules,
			loaded:      p.indexing.loaded,
			unreadable:  p.indexing.unreadable,
			fingerprint: p.indexing.configFingerprint,
		}
	})
	var info projectSnapshot
	select {
	case info = <-infoCh:
	case <-ctx.Done():
		return settingswindow.DirectoryMarksSnapshot{}, ctx.Err()
	}
	if info.p == nil {
		return settingswindow.DirectoryMarksSnapshot{}, errors.New("no local project open")
	}
	if !info.loaded {
		return settingswindow.DirectoryMarksSnapshot{}, errors.New("directory rules are still loading")
	}
	if info.unreadable {
		return settingswindow.DirectoryMarksSnapshot{}, errors.New("stored directory rules are unreadable")
	}
	if next.WorkspaceRoot != "" && info.root != next.WorkspaceRoot {
		return settingswindow.DirectoryMarksSnapshot{}, errors.New("active workspace changed; reload directory marks settings before saving")
	}
	meta, ok := s.app.kernel.(directoryMetaKernel)
	if !ok || s.app.store == nil {
		return settingswindow.DirectoryMarksSnapshot{}, errors.New("directory metadata kernel unavailable")
	}
	expectedFP := next.ConfigFingerprint
	if expectedFP == "" {
		expectedFP = info.fingerprint
	}
	if expectedFP != "" {
		diskFP, err := directoryRulesFingerprint(s.app.store.Dir(), info.root)
		if err != nil {
			return settingswindow.DirectoryMarksSnapshot{}, err
		}
		if diskFP != expectedFP {
			return settingswindow.DirectoryMarksSnapshot{}, errors.New("private directory config changed on disk; reload before saving")
		}
	}

	rules := info.rules
	if len(rules) == 0 {
		rules = core.EmptyDirectoryRules()
	}
	beforeState := core.ParseDirectoryRules(rules)

	// Reconcile custom types through Core's reducer so validation and normalization stay in Core.
	desiredIDs := make(map[string]bool, len(next.CustomTypes))
	for _, ct := range next.CustomTypes {
		desiredIDs[ct.ID] = true
		var err error
		_, rules, err = meta.UpsertCustomDirectoryType(ctx, ct, rules)
		if err != nil {
			return settingswindow.DirectoryMarksSnapshot{}, err
		}
	}
	for _, old := range beforeState.CustomTypes {
		if !desiredIDs[old.ID] {
			var err error
			_, rules, err = meta.DeleteCustomDirectoryType(ctx, old.ID, rules)
			if err != nil {
				return settingswindow.DirectoryMarksSnapshot{}, err
			}
		}
	}

	sharedPath := strings.TrimSpace(next.SharedConfigPath)
	if sharedPath == "" {
		sharedPath = defaultSharedDirectoryRulesPath
	}
	var sharedRules json.RawMessage
	if next.SharedConfigEnabled {
		if _, err := resolveWorkspaceFilePath(info.root, sharedPath); err != nil {
			return settingswindow.DirectoryMarksSnapshot{}, err
		}
		raw, exists, err := readSharedDirectoryRules(info.root, sharedPath)
		if err != nil {
			return settingswindow.DirectoryMarksSnapshot{}, err
		}
		if !exists {
			if err := writeSharedDirectoryRules(info.root, sharedPath, core.EmptyDirectoryRules()); err != nil {
				return settingswindow.DirectoryMarksSnapshot{}, err
			}
			sharedRules = core.EmptyDirectoryRules()
		} else {
			sharedRules = raw
		}
	}

	if err := s.app.store.Save(directoryRulesName(info.root), directoryRulesFile{
		Root:                info.root,
		Rules:               rules,
		GitIgnoreDisabled:   !next.GitIgnoreEnabled,
		SharedConfigEnabled: next.SharedConfigEnabled,
		SharedConfigPath:    sharedPath,
		HideBgTint:          !next.ShowBgTint,
		HideTags:            !next.ShowTags,
		CustomTypesSeeded:   true,
	}); err != nil {
		return settingswindow.DirectoryMarksSnapshot{}, err
	}
	newFP, _ := directoryRulesFingerprint(s.app.store.Dir(), info.root)

	done := make(chan settingswindow.DirectoryMarksSnapshot, 1)
	s.app.post(func(a *App) {
		p := info.p
		p.indexing.rules = rules
		p.indexing.gitIgnore = next.GitIgnoreEnabled
		p.indexing.sharedConfigEnabled = next.SharedConfigEnabled
		p.indexing.sharedConfigPath = sharedPath
		p.indexing.sharedRules = sharedRules
		p.indexing.hideBgTint = !next.ShowBgTint
		p.indexing.hideTags = !next.ShowTags
		p.indexing.customIconCache = nil
		if newFP != "" {
			p.indexing.configFingerprint = newFP
		}
		if a.project == p {
			a.installIndexing(p, true)
		}
		done <- s.snapshotOf(p)
	})
	select {
	case snap := <-done:
		return snap, nil
	case <-ctx.Done():
		return settingswindow.DirectoryMarksSnapshot{}, ctx.Err()
	}
}

func (s appDirectoryMarks) ImportIcon(ctx context.Context, base settingswindow.DirectoryMarksSnapshot, sourcePath string) (settingswindow.DirectoryMarksSnapshot, error) {
	if s.app == nil || s.app.store == nil {
		return settingswindow.DirectoryMarksSnapshot{}, errors.New("store unavailable")
	}
	meta, ok := s.app.kernel.(directoryMetaKernel)
	if !ok {
		return settingswindow.DirectoryMarksSnapshot{}, errors.New("directory metadata kernel unavailable")
	}
	data, err := os.ReadFile(sourcePath)
	if err != nil {
		return settingswindow.DirectoryMarksSnapshot{}, err
	}
	if int64(len(data)) > pluginicons.MaxFileBytes {
		return settingswindow.DirectoryMarksSnapshot{}, errors.New("SVG icon exceeds size limit")
	}
	if _, err := pluginicons.CompileSVG(sourcePath, data); err != nil {
		return settingswindow.DirectoryMarksSnapshot{}, err
	}

	baseName := strings.TrimSuffix(filepath.Base(sourcePath), filepath.Ext(sourcePath))
	slug := sanitizeIconSlug(baseName)
	if slug == "" {
		slug = "custom"
	}
	id := fmt.Sprintf("icon.%s_%d", slug, time.Now().UnixMilli()%100000)
	relPath := filepath.ToSlash(filepath.Join(customDirectoryIconsDir, id+".svg"))
	destPath := filepath.Join(s.app.store.Dir(), filepath.FromSlash(relPath))

	return s.mutateRulesIcon(ctx, base, func() error {
		return atomicfile.Write(destPath, data, 0o644)
	}, func() {
		_ = os.Remove(destPath)
	}, func(rules json.RawMessage) (bool, json.RawMessage, error) {
		return meta.UpsertCustomDirectoryIcon(ctx, core.CustomDirectoryIcon{
			ID:   id,
			Name: baseName,
			Path: relPath,
		}, rules)
	}, "")
}

func (s appDirectoryMarks) DeleteIcon(ctx context.Context, base settingswindow.DirectoryMarksSnapshot, id string) (settingswindow.DirectoryMarksSnapshot, error) {
	if s.app == nil || s.app.store == nil {
		return settingswindow.DirectoryMarksSnapshot{}, errors.New("store unavailable")
	}
	meta, ok := s.app.kernel.(directoryMetaKernel)
	if !ok {
		return settingswindow.DirectoryMarksSnapshot{}, errors.New("directory metadata kernel unavailable")
	}
	return s.mutateRulesIcon(ctx, base, nil, nil, func(rules json.RawMessage) (bool, json.RawMessage, error) {
		return meta.DeleteCustomDirectoryIcon(ctx, id, rules)
	}, id)
}

func (s appDirectoryMarks) mutateRulesIcon(
	ctx context.Context,
	base settingswindow.DirectoryMarksSnapshot,
	beforeSave func() error,
	rollbackBeforeSave func(),
	reduce func(json.RawMessage) (bool, json.RawMessage, error),
	removeIconID string,
) (settingswindow.DirectoryMarksSnapshot, error) {
	type reqInfo struct {
		p           *project
		root        string
		loaded      bool
		unreadable  bool
		fingerprint string
		file        directoryRulesFile
	}
	ch := make(chan reqInfo, 1)
	s.app.post(func(a *App) {
		p := s.activeLocalProject()
		if p == nil {
			ch <- reqInfo{}
			return
		}
		ch <- reqInfo{
			p:           p,
			root:        p.root,
			loaded:      p.indexing.loaded,
			unreadable:  p.indexing.unreadable,
			fingerprint: p.indexing.configFingerprint,
			file: directoryRulesFile{
				Root:                p.root,
				Rules:               p.indexing.rules,
				GitIgnoreDisabled:   !p.indexing.gitIgnore,
				SharedConfigEnabled: p.indexing.sharedConfigEnabled,
				SharedConfigPath:    p.indexing.sharedConfigPath,
				HideBgTint:          p.indexing.hideBgTint,
				HideTags:            p.indexing.hideTags,
				CustomTypesSeeded:   true,
			},
		}
	})
	var info reqInfo
	select {
	case info = <-ch:
	case <-ctx.Done():
		return settingswindow.DirectoryMarksSnapshot{}, ctx.Err()
	}
	if info.p == nil {
		return settingswindow.DirectoryMarksSnapshot{}, errors.New("no local project open")
	}
	if !info.loaded {
		return settingswindow.DirectoryMarksSnapshot{}, errors.New("directory rules are still loading")
	}
	if info.unreadable {
		return settingswindow.DirectoryMarksSnapshot{}, errors.New("stored directory rules are unreadable")
	}
	if base.WorkspaceRoot != "" && info.root != base.WorkspaceRoot {
		return settingswindow.DirectoryMarksSnapshot{}, errors.New("active workspace changed; reload directory marks settings before saving")
	}
	expectedFP := base.ConfigFingerprint
	if expectedFP == "" {
		expectedFP = info.fingerprint
	}
	if expectedFP != "" {
		diskFP, err := directoryRulesFingerprint(s.app.store.Dir(), info.root)
		if err != nil {
			return settingswindow.DirectoryMarksSnapshot{}, err
		}
		if diskFP != expectedFP {
			return settingswindow.DirectoryMarksSnapshot{}, errors.New("private directory config changed on disk; reload before saving")
		}
	}

	beforeState := core.ParseDirectoryRules(info.file.Rules)
	_, nextRules, err := reduce(info.file.Rules)
	if err != nil {
		return settingswindow.DirectoryMarksSnapshot{}, err
	}
	if beforeSave != nil {
		if err := beforeSave(); err != nil {
			return settingswindow.DirectoryMarksSnapshot{}, err
		}
	}
	info.file.Rules = nextRules
	if err := s.app.store.Save(directoryRulesName(info.root), info.file); err != nil {
		if rollbackBeforeSave != nil {
			rollbackBeforeSave()
		}
		return settingswindow.DirectoryMarksSnapshot{}, err
	}
	newFP, _ := directoryRulesFingerprint(s.app.store.Dir(), info.root)
	if removeIconID != "" {
		for _, ci := range beforeState.CustomIcons {
			if ci.ID == removeIconID {
				full := filepath.Join(s.app.store.Dir(), filepath.FromSlash(ci.Path))
				if err := os.Remove(full); err != nil && !errors.Is(err, os.ErrNotExist) {
					s.app.operationFailedIn(ctx, "directory_custom_icon_remove", err)
				}
			}
		}
	}
	done := make(chan settingswindow.DirectoryMarksSnapshot, 1)
	s.app.post(func(a *App) {
		info.p.indexing.rules = nextRules
		info.p.indexing.customIconCache = nil
		if newFP != "" {
			info.p.indexing.configFingerprint = newFP
		}
		if a.project == info.p {
			a.refreshDirectoryPresentation(info.p)
		}
		done <- s.snapshotOf(info.p)
	})
	select {
	case snap := <-done:
		return snap, nil
	case <-ctx.Done():
		return settingswindow.DirectoryMarksSnapshot{}, ctx.Err()
	}
}

func (s appDirectoryMarks) OpenFile(target string) {
	if s.app == nil || strings.TrimSpace(target) == "" {
		return
	}
	s.app.post(func(a *App) {
		p := s.activeLocalProject()
		if p == nil {
			return
		}
		full := target
		if !filepath.IsAbs(full) {
			resolved, err := resolveWorkspaceFilePath(p.root, full)
			if err != nil {
				a.operationFailed("directory_config_open", err)
				return
			}
			full = resolved
		}
		a.openFile(p, full)
	})
}

func sanitizeIconSlug(raw string) string {
	var b strings.Builder
	for _, r := range strings.ToLower(raw) {
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') || r == '_' || r == '-' {
			b.WriteRune(r)
		}
	}
	out := b.String()
	if len(out) > 24 {
		return out[:24]
	}
	return out
}
