package workbench

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"slices"
	"strconv"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/settingswindow"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

func TestDirectoryMetadataEndToEndWithCore(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	client := core.NewClient()
	rules := core.EmptyDirectoryRules()

	// 1. Add custom directory type and custom SVG icon via Core.
	changed, rules, err := client.UpsertCustomDirectoryIcon(ctx, core.CustomDirectoryIcon{
		ID:   "icon.rocket",
		Name: "Rocket",
		Path: "directory-icons/icon.rocket.svg",
	}, rules)
	if err != nil || !changed {
		t.Fatalf("UpsertCustomDirectoryIcon failed: changed=%v err=%v", changed, err)
	}

	changed, rules, err = client.UpsertCustomDirectoryType(ctx, core.CustomDirectoryType{
		ID:              "custom.core",
		Name:            "Core Business",
		Tag:             "core",
		Icon:            "icon.rocket",
		Color:           "#4E8DF5",
		TintBg:          true,
		TintText:        true,
		InheritBg:       true,
		ExcludeIndexing: false,
	}, rules)
	if err != nil || !changed {
		t.Fatalf("UpsertCustomDirectoryType failed: changed=%v err=%v", changed, err)
	}

	// 2. Mark directories and set quick color override.
	_, rules, err = client.SetDirectoryRole(ctx, "src/orders", "custom.core", false, rules)
	if err != nil {
		t.Fatalf("SetDirectoryRole custom.core failed: %v", err)
	}
	_, rules, err = client.SetDirectoryRole(ctx, "src/test", "tests", false, rules)
	if err != nil {
		t.Fatalf("SetDirectoryRole tests failed: %v", err)
	}
	_, rules, err = client.SetDirectoryColor(ctx, "src/test", "#57AB5A", false, rules)
	if err != nil {
		t.Fatalf("SetDirectoryColor failed: %v", err)
	}

	// 3. Resolve presentation including inheritance and Git ignores.
	res, err := client.ResolveDirectoryPresentation(ctx, rules, nil, nil, nil, []string{"target"}, false, []string{
		"src/orders",
		"src/orders/Order.java",
		"src/test",
		"target",
	})
	if err != nil {
		t.Fatalf("ResolveDirectoryPresentation failed: %v", err)
	}
	orders := res.Entries["src/orders"]
	if orders.Role != "custom.core" || orders.Icon != "icon.rocket" || orders.Color != "#4e8df5" || !orders.TintText || orders.Tag != "core" {
		t.Fatalf("unexpected src/orders entry: %+v", orders)
	}
	orderFile := res.Entries["src/orders/Order.java"]
	if orderFile.Source != "inherited" || orderFile.BgColor != "#4e8df5" {
		t.Fatalf("expected child to inherit bgColor, got %+v", orderFile)
	}
	target := res.Entries["target"]
	if !target.Excluded || target.Source != "vcs" {
		t.Fatalf("expected target to be vcs-excluded, got %+v", target)
	}

	// 4. Shared config roundtrip stays inside workspace root.
	root := t.TempDir()
	if err := writeSharedDirectoryRules(root, defaultSharedDirectoryRulesPath, rules); err != nil {
		t.Fatalf("writeSharedDirectoryRules failed: %v", err)
	}
	loaded, exists, err := readSharedDirectoryRules(root, defaultSharedDirectoryRulesPath)
	if err != nil || !exists || len(loaded) == 0 {
		t.Fatalf("readSharedDirectoryRules failed: exists=%v err=%v", exists, err)
	}
	if _, _, err := readSharedDirectoryRules(root, "../escape.json"); err == nil {
		t.Fatal("expected escaping shared path to be rejected")
	}

	// 5. Custom SVG icon file compiles cleanly from user store directory.
	st := store.At(t.TempDir())
	svg := []byte(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><circle cx="8" cy="8" r="6" fill="currentColor"/></svg>`)
	iconDest := filepath.Join(st.Dir(), "directory-icons", "icon.rocket.svg")
	if err := os.MkdirAll(filepath.Dir(iconDest), 0o755); err != nil {
		t.Fatalf("mkdir icon dir: %v", err)
	}
	if err := os.WriteFile(iconDest, svg, 0o644); err != nil {
		t.Fatalf("write icon svg: %v", err)
	}
	var decoded json.RawMessage = rules
	a := &App{store: st}
	p := &project{indexing: projectIndexing{rules: decoded}}
	compiled := a.directoryIconFor(p, "icon.rocket")
	if reflect.DeepEqual(compiled, directoryIcon("folder", false)) {
		t.Fatal("expected compiled custom SVG icon rather than folder fallback")
	}
}

func TestDirectorySharedConfigRejectsSymlinkEscape(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("symlink creation requires elevated privileges on Windows")
	}
	root := t.TempDir()
	outside := t.TempDir()
	secret := filepath.Join(outside, "secret.json")
	if err := os.WriteFile(secret, []byte(`{"schemaVersion":1,"rules":{"marks":{}}}`), 0o644); err != nil {
		t.Fatalf("write outside file: %v", err)
	}
	if err := os.MkdirAll(filepath.Join(root, ".lithe"), 0o755); err != nil {
		t.Fatalf("mkdir .lithe: %v", err)
	}
	// 1. Symlinked file inside workspace pointing outside.
	if err := os.Symlink(secret, filepath.Join(root, ".lithe", "directories.json")); err != nil {
		t.Fatalf("symlink file: %v", err)
	}
	if _, _, err := readSharedDirectoryRules(root, ".lithe/directories.json"); err == nil {
		t.Fatal("expected symlinked shared config file to be rejected")
	}
	if err := writeSharedDirectoryRules(root, ".lithe/directories.json", core.EmptyDirectoryRules()); err == nil {
		t.Fatal("expected write through symlinked shared config file to be rejected")
	}

	// 2. Symlinked parent directory pointing outside with a non-existent target leaf.
	if err := os.Symlink(outside, filepath.Join(root, "escape-dir")); err != nil {
		t.Fatalf("symlink dir: %v", err)
	}
	if err := writeSharedDirectoryRules(root, "escape-dir/new.json", core.EmptyDirectoryRules()); err == nil {
		t.Fatal("expected write through symlinked parent directory to be rejected")
	}
}

func TestDirectoryEffectiveIndexingPrecedenceAndGlobs(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	client := core.NewClient()
	root := t.TempDir()
	for _, dir := range []string{"src/api", "legacy/old-v1", "shared-only"} {
		if err := os.MkdirAll(filepath.Join(root, filepath.FromSlash(dir)), 0o755); err != nil {
			t.Fatalf("mkdir %s: %v", dir, err)
		}
	}

	// Shared rules exclude src/api and shared-only.
	shared := core.EmptyDirectoryRules()
	var err error
	_, shared, err = client.ExcludeDirectory(ctx, "src/api", false, shared)
	if err != nil {
		t.Fatalf("shared exclude src/api: %v", err)
	}
	_, shared, err = client.ExcludeDirectory(ctx, "shared-only", false, shared)
	if err != nil {
		t.Fatalf("shared exclude shared-only: %v", err)
	}

	// Local rules override src/api to sources and define a glob-excluding custom type for legacy/**.
	local := core.EmptyDirectoryRules()
	_, local, err = client.SetDirectoryRole(ctx, "src/api", "sources", false, local)
	if err != nil {
		t.Fatalf("local setRole src/api: %v", err)
	}
	_, local, err = client.UpsertCustomDirectoryType(ctx, core.CustomDirectoryType{
		ID:              "custom.legacy",
		Name:            "Legacy",
		Tag:             "legacy",
		Icon:            "archive",
		Color:           "#8b949e",
		ExcludeIndexing: true,
		MatchGlob:       "legacy/**",
	}, local)
	if err != nil {
		t.Fatalf("upsert custom.legacy: %v", err)
	}

	policy, pluginErr, err := resolveEffectiveIndexingPolicy(ctx, client, root, local, shared, nil, nil, false)
	if pluginErr != nil || err != nil {
		t.Fatalf("resolveEffectiveIndexingPolicy: pluginErr=%v err=%v", pluginErr, err)
	}
	if slices.Contains(policy.ManualExcludedDirectories, "src/api") {
		t.Fatalf("local sources mark must override shared exclusion, got %v", policy.ManualExcludedDirectories)
	}
	if !slices.Contains(policy.ManualExcludedDirectories, "shared-only") {
		t.Fatalf("expected shared-only to remain excluded, got %v", policy.ManualExcludedDirectories)
	}
	if !slices.Contains(policy.ManualExcludedDirectories, "legacy/old-v1") {
		t.Fatalf("expected glob-matched legacy/old-v1 to be excluded from indexing, got %v", policy.ManualExcludedDirectories)
	}
}

func TestDirectorySettingsGuardsWorkspaceConflictAndUnreadable(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	client := core.NewClient()
	st := store.At(t.TempDir())
	rootA := t.TempDir()
	rootB := t.TempDir()

	// Seed a valid private config for project A.
	if err := st.Save(directoryRulesName(rootA), directoryRulesFile{
		Root:              rootA,
		Rules:             core.EmptyDirectoryRules(),
		CustomTypesSeeded: true,
	}); err != nil {
		t.Fatalf("seed project A rules: %v", err)
	}
	fpA, err := directoryRulesFingerprint(st.Dir(), rootA)
	if err != nil {
		t.Fatalf("fingerprint A: %v", err)
	}

	projA := &project{
		root: rootA,
		indexing: projectIndexing{
			rules:             core.EmptyDirectoryRules(),
			loaded:            true,
			gitIgnore:         true,
			configFingerprint: fpA,
		},
	}
	a := &App{
		kernel:  client,
		store:   st,
		project: projA,
	}
	src := appDirectoryMarks{app: a}
	runDrained := func(fn func() (settingswindow.DirectoryMarksSnapshot, error)) (settingswindow.DirectoryMarksSnapshot, error) {
		type res struct {
			snap settingswindow.DirectoryMarksSnapshot
			err  error
		}
		ch := make(chan res, 1)
		go func() {
			snap, err := fn()
			ch <- res{snap: snap, err: err}
		}()
		ticker := time.NewTicker(time.Millisecond)
		defer ticker.Stop()
		for {
			a.drain()
			select {
			case out := <-ch:
				return out.snap, out.err
			case <-ticker.C:
			}
		}
	}

	snapA, err := runDrained(func() (settingswindow.DirectoryMarksSnapshot, error) {
		return src.Load(ctx)
	})
	if err != nil {
		t.Fatalf("Load A: %v", err)
	}
	if snapA.WorkspaceRoot != rootA || snapA.ConfigFingerprint != fpA {
		t.Fatalf("unexpected snapshot metadata: root=%q fp=%q", snapA.WorkspaceRoot, snapA.ConfigFingerprint)
	}

	// 1. Switching active project to B must reject saving A's stale draft.
	a.project = &project{
		root: rootB,
		indexing: projectIndexing{
			rules:             core.EmptyDirectoryRules(),
			loaded:            true,
			gitIgnore:         true,
			configFingerprint: "missing",
		},
	}
	if _, err := runDrained(func() (settingswindow.DirectoryMarksSnapshot, error) {
		return src.Save(ctx, snapA)
	}); err == nil {
		t.Fatal("expected Save with mismatched WorkspaceRoot to fail")
	}

	// 2. External edit on disk must be rejected instead of silently overwritten.
	a.project = projA
	if err := st.Save(directoryRulesName(rootA), directoryRulesFile{
		Root:              rootA,
		Rules:             core.EmptyDirectoryRules(),
		HideTags:          true,
		CustomTypesSeeded: true,
	}); err != nil {
		t.Fatalf("external edit project A: %v", err)
	}
	if _, err := runDrained(func() (settingswindow.DirectoryMarksSnapshot, error) {
		return src.Save(ctx, snapA)
	}); err == nil {
		t.Fatal("expected Save after external disk edit to fail")
	}

	// 3. Unreadable rules must block ImportIcon BEFORE writing any SVG file.
	projA.indexing.unreadable = true
	svgPath := filepath.Join(t.TempDir(), "badge.svg")
	if err := os.WriteFile(svgPath, []byte(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><circle cx="8" cy="8" r="6" fill="currentColor"/></svg>`), 0o644); err != nil {
		t.Fatalf("write svg: %v", err)
	}
	if _, err := runDrained(func() (settingswindow.DirectoryMarksSnapshot, error) {
		return src.ImportIcon(ctx, settingswindow.DirectoryMarksSnapshot{WorkspaceRoot: rootA}, svgPath)
	}); err == nil {
		t.Fatal("expected ImportIcon to fail when rules are unreadable")
	}
	entries, _ := os.ReadDir(filepath.Join(st.Dir(), customDirectoryIconsDir))
	if len(entries) != 0 {
		t.Fatalf("expected no SVG file written on rejected ImportIcon, found %d", len(entries))
	}
}

func TestDirectoryRelocateRulesWithCore(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	client := core.NewClient()
	rules := core.EmptyDirectoryRules()
	var err error
	_, rules, err = client.SetDirectoryRole(ctx, "src/orders", "sources", false, rules)
	if err != nil {
		t.Fatalf("setRole: %v", err)
	}
	_, rules, err = client.SetDirectoryColor(ctx, "src/orders", "#4e8df5", false, rules)
	if err != nil {
		t.Fatalf("setColor: %v", err)
	}

	moved, err := client.RelocateDirectoryRules(ctx, "src/orders", "src/billing", false, rules)
	if err != nil {
		t.Fatalf("RelocateDirectoryRules move: %v", err)
	}
	state := core.ParseDirectoryRules(moved)
	if state.Marks["src/billing"] != "sources" || state.Colors["src/billing"] != "#4e8df5" {
		t.Fatalf("expected mark and color moved to src/billing, got %+v", state)
	}
	if _, exists := state.Marks["src/orders"]; exists {
		t.Fatalf("expected old key removed, got %+v", state.Marks)
	}

	deleted, err := client.RelocateDirectoryRules(ctx, "src/billing", "", false, moved)
	if err != nil {
		t.Fatalf("RelocateDirectoryRules delete: %v", err)
	}
	afterDel := core.ParseDirectoryRules(deleted)
	if len(afterDel.Marks) != 0 || len(afterDel.Colors) != 0 {
		t.Fatalf("expected marks and colors dropped after delete, got %+v", afterDel)
	}
}

func TestDirectoryPluginTypesAndMarksEndToEnd(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	client := core.NewClient()
	root := t.TempDir()
	for _, dir := range []string{"db/migrations", "vendor/cache", "manual-override"} {
		if err := os.MkdirAll(filepath.Join(root, filepath.FromSlash(dir)), 0o755); err != nil {
			t.Fatalf("mkdir %s: %v", dir, err)
		}
	}

	pluginTypes := []core.PluginDirectoryType{
		{
			PluginID: "com.example.sql",
			ID:       "plugin.migrations",
			Name:     "SQL Migrations",
			Tag:      "migrations",
			Icon:     "database",
			Color:    "#0d9488",
		},
		{
			PluginID:        "com.example.cache",
			ID:              "plugin.cache",
			Name:            "Cache",
			Tag:             "cache",
			Icon:            "archive",
			Color:           "#64748b",
			ExcludeIndexing: true,
			MatchGlob:       "vendor/**",
		},
	}
	pluginMarks := []core.PluginDirectoryMark{
		{PluginID: "com.example.sql", Path: "db/migrations", Role: "plugin.migrations"},
		{PluginID: "com.example.cache", Path: "manual-override", Role: "excluded"},
	}

	// Local user override beats plugin exclusion.
	rules := core.EmptyDirectoryRules()
	var err error
	_, rules, err = client.SetDirectoryRole(ctx, "manual-override", "sources", false, rules)
	if err != nil {
		t.Fatalf("SetDirectoryRole: %v", err)
	}

	res, err := client.ResolveDirectoryPresentation(ctx, rules, nil, pluginTypes, pluginMarks, nil, false, []string{
		"db/migrations",
		"vendor/cache",
		"manual-override",
	})
	if err != nil {
		t.Fatalf("ResolveDirectoryPresentation: %v", err)
	}
	if got := res.Entries["db/migrations"]; got.Role != "plugin.migrations" || got.Source != "plugin" || got.PluginID != "com.example.sql" || got.Tag != "migrations" {
		t.Fatalf("unexpected plugin mark entry: %+v", got)
	}
	if got := res.Entries["manual-override"]; got.Role != "sources" || got.Source != "user" || got.Excluded {
		t.Fatalf("user override must beat plugin exclusion: %+v", got)
	}

	policy, pluginErr, err := resolveEffectiveIndexingPolicy(ctx, client, root, rules, nil, pluginTypes, pluginMarks, false)
	if pluginErr != nil || err != nil {
		t.Fatalf("resolveEffectiveIndexingPolicy: pluginErr=%v err=%v", pluginErr, err)
	}
	if !slices.Contains(policy.ManualExcludedDirectories, "vendor/cache") {
		t.Fatalf("expected plugin glob exclusion vendor/cache in indexing policy, got %v", policy.ManualExcludedDirectories)
	}
	if slices.Contains(policy.ManualExcludedDirectories, "manual-override") {
		t.Fatalf("expected user override to keep manual-override indexed, got %v", policy.ManualExcludedDirectories)
	}
}

// A plugin that only marks folders as excluded, with no glob anywhere, has no candidate paths
// to ask Core about; its exclusions must still reach the indexing policy.
func TestPluginExclusionMarksReachIndexingWithoutGlobs(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	client := core.NewClient()
	root := t.TempDir()
	pluginTypes := []core.PluginDirectoryType{{
		PluginID:        "com.example.gen",
		ID:              "plugin.generated-cache",
		Name:            "Generated cache",
		Icon:            "generated",
		Color:           "#64748b",
		ExcludeIndexing: true,
	}}
	pluginMarks := []core.PluginDirectoryMark{
		{PluginID: "com.example.gen", Path: "gen", Role: "plugin.generated-cache"},
		{PluginID: "com.example.gen", Path: "vendor", Role: "excluded"},
	}

	res, err := client.ResolveDirectoryPresentation(ctx, core.EmptyDirectoryRules(), nil, pluginTypes, pluginMarks, nil, false, nil)
	if err != nil {
		t.Fatalf("ResolveDirectoryPresentation without paths: %v", err)
	}
	if want := []string{"gen", "vendor"}; !slices.Equal(res.ManualExcludedDirectories, want) {
		t.Fatalf("manualExcludedDirectories = %v, want %v", res.ManualExcludedDirectories, want)
	}

	policy, pluginErr, err := resolveEffectiveIndexingPolicy(ctx, client, root, core.EmptyDirectoryRules(), nil, pluginTypes, pluginMarks, false)
	if pluginErr != nil || err != nil {
		t.Fatalf("resolveEffectiveIndexingPolicy: pluginErr=%v err=%v", pluginErr, err)
	}
	if want := []string{"gen", "vendor"}; !slices.Equal(policy.ManualExcludedDirectories, want) {
		t.Fatalf("policy exclusions = %v, want %v", policy.ManualExcludedDirectories, want)
	}
}

// When Core refuses the plugin layers as a whole (more types than it resolves at once, summed
// over every plugin session), the user's own rules must still apply, and the refusal is
// reported rather than dropped.
func TestPluginLayersCoreRefusesLeaveUserRulesInForce(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	client := core.NewClient()
	root := t.TempDir()
	rules := core.EmptyDirectoryRules()
	var err error
	_, rules, err = client.ExcludeDirectory(ctx, "build", false, rules)
	if err != nil {
		t.Fatalf("ExcludeDirectory: %v", err)
	}
	var pluginTypes []core.PluginDirectoryType
	for i := range 257 {
		pluginTypes = append(pluginTypes, core.PluginDirectoryType{
			PluginID: "com.example.many",
			ID:       "plugin.t" + strconv.Itoa(i),
			Name:     "Type",
			Icon:     "folder",
			Color:    "#64748b",
		})
	}
	pluginMarks := []core.PluginDirectoryMark{{PluginID: "com.example.many", Path: "out", Role: "excluded"}}

	policy, pluginErr, err := resolveEffectiveIndexingPolicy(ctx, client, root, rules, nil, pluginTypes, pluginMarks, false)
	if pluginErr == nil {
		t.Fatal("expected Core to refuse more than 256 plugin types")
	}
	if err != nil {
		t.Fatalf("resolving without the plugin layers failed: %v", err)
	}
	if want := []string{"build"}; !slices.Equal(policy.ManualExcludedDirectories, want) {
		t.Fatalf("policy exclusions = %v, want only the user's %v", policy.ManualExcludedDirectories, want)
	}

	res, pluginErr, err := resolveDirectoryLayers(ctx, client, rules, nil, pluginTypes, pluginMarks, nil, []string{"build", "out"})
	if pluginErr == nil || err != nil {
		t.Fatalf("resolveDirectoryLayers: pluginErr=%v err=%v", pluginErr, err)
	}
	if got := res.Entries["build"]; !got.Excluded || got.Source != "user" {
		t.Fatalf("user exclusion must still show: %+v", got)
	}
	if got := res.Entries["out"]; got.Excluded || got.PluginID != "" {
		t.Fatalf("refused plugin layers must not show: %+v", got)
	}
}

// The same plugin can hold the same type ID or path in two sessions or contexts; the merged
// list Core and the menus see must come out in the same order every time.
func TestPluginDirectoryLayersMergeInStableOrder(t *testing.T) {
	p := &project{}
	p.indexing.pluginTypesByKey = map[string][]core.PluginDirectoryType{
		"s2:c1:directoryTypes": {{PluginID: "com.example.a", ID: "plugin.x", Name: "Second"}},
		"s1:c1:directoryTypes": {{PluginID: "com.example.a", ID: "plugin.x", Name: "First"}},
		"s3:c1:directoryTypes": {{PluginID: "com.example.0", ID: "plugin.z", Name: "Zero"}},
	}
	p.indexing.pluginMarksByKey = map[string][]core.PluginDirectoryMark{
		"s2:c1:directoryMarks": {{PluginID: "com.example.a", Path: "src", Role: "tests"}},
		"s1:c1:directoryMarks": {{PluginID: "com.example.a", Path: "src", Role: "sources"}},
	}
	for range 50 {
		types := p.pluginDirectoryTypes()
		if names := []string{types[0].Name, types[1].Name, types[2].Name}; !slices.Equal(names, []string{"Zero", "First", "Second"}) {
			t.Fatalf("plugin types order = %v", names)
		}
		marks := p.pluginDirectoryMarks()
		if roles := []string{marks[0].Role, marks[1].Role}; !slices.Equal(roles, []string{"sources", "tests"}) {
			t.Fatalf("plugin marks order = %v", roles)
		}
	}
}

// A folder created after the policy's directory walk that an excluding plugin glob matches is
// still searchable; the presentation refresh that shows it must ask for a new policy, once.
func TestFolderCreatedAfterPolicyAsksOnceForGlobExclusion(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	client := core.NewClient()
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "vendor", "old"), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	pluginTypes := []core.PluginDirectoryType{{
		PluginID:        "com.example.cache",
		ID:              "plugin.cache",
		Name:            "Cache",
		Icon:            "archive",
		Color:           "#64748b",
		ExcludeIndexing: true,
		MatchGlob:       "vendor/**",
	}}
	rules := core.EmptyDirectoryRules()
	policy, pluginErr, err := resolveEffectiveIndexingPolicy(ctx, client, root, rules, nil, pluginTypes, nil, false)
	if pluginErr != nil || err != nil {
		t.Fatalf("resolveEffectiveIndexingPolicy: pluginErr=%v err=%v", pluginErr, err)
	}
	ix := &projectIndexing{policyExcluded: map[string]struct{}{}}
	for _, dir := range policy.ManualExcludedDirectories {
		ix.policyExcluded[dir] = struct{}{}
	}
	if _, ok := ix.policyExcluded["vendor/old"]; !ok {
		t.Fatalf("walk at install must exclude vendor/old, got %v", policy.ManualExcludedDirectories)
	}

	rows := []string{"vendor", "vendor/old"}
	res, err := client.ResolveDirectoryPresentation(ctx, rules, nil, pluginTypes, nil, nil, false, rows)
	if err != nil {
		t.Fatalf("ResolveDirectoryPresentation: %v", err)
	}
	if ix.staleGlobExclusions(res.Entries) {
		t.Fatalf("folders the policy already excludes must not ask again: %+v", res.Entries)
	}

	rows = append(rows, "vendor/new")
	res, err = client.ResolveDirectoryPresentation(ctx, rules, nil, pluginTypes, nil, nil, false, rows)
	if err != nil {
		t.Fatalf("ResolveDirectoryPresentation: %v", err)
	}
	if got := res.Entries["vendor/new"]; got.Source != "glob" || !got.Excluded {
		t.Fatalf("expected vendor/new to match the excluding glob: %+v", got)
	}
	if !ix.staleGlobExclusions(res.Entries) {
		t.Fatal("a new glob-matched folder must ask for a new policy")
	}
	if ix.staleGlobExclusions(res.Entries) {
		t.Fatal("the same folder must ask only once")
	}
	if (&projectIndexing{}).staleGlobExclusions(res.Entries) {
		t.Fatal("before any policy is installed nothing is stale")
	}
}
