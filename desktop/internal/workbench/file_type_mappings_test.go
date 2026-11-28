package workbench

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/syntax"
	"github.com/1lck/Lithe-IDEA/desktop/internal/installedpackagetest"
	"github.com/1lck/Lithe-IDEA/desktop/internal/settingswindow"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

func runFileTypeMappingsOp[T any](t *testing.T, h *harness, fn func(context.Context) (T, error)) (T, error) {
	t.Helper()
	type outcome struct {
		val T
		err error
	}
	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()
	ch := make(chan outcome, 1)
	go func() {
		v, err := fn(ctx)
		ch <- outcome{val: v, err: err}
	}()
	ticker := time.NewTicker(time.Millisecond)
	defer ticker.Stop()
	for {
		h.app.drain()
		select {
		case out := <-ch:
			h.settle()
			return out.val, out.err
		case <-ticker.C:
		case <-ctx.Done():
			var zero T
			return zero, ctx.Err()
		}
	}
}

func TestOpenUVLockResolvesToTOMLWithHighlightAndLineComments(t *testing.T) {
	root := t.TempDir()
	uvLock := filepath.Join(root, "uv.lock")
	if err := os.WriteFile(uvLock, []byte("version = 1\n[package]\nname = \"demo\"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(root)
	p := h.app.project

	h.app.openFile(p, uvLock)
	h.settle()

	doc := p.docs.byPath(uvLock)
	if doc == nil {
		t.Fatal("uv.lock did not open")
	}
	if doc.languageID != "toml" {
		t.Fatalf("languageID = %q, want toml", doc.languageID)
	}
	if doc.grammar == nil || doc.grammar.Language().ID != "toml" {
		t.Fatalf("grammar = %v, want toml", doc.grammar)
	}
	tokens := doc.view.SyntaxLine(nil, 2)
	if len(tokens) == 0 {
		t.Fatal("expected TOML syntax tokens for uv.lock")
	}
	doc.view.GoToLine(1)
	h.app.runLineOperation(p, doc, core.ToggleLineComment)
	h.settle()
	if got := doc.view.TextSnapshot().String(); !strings.HasPrefix(got, "# version = 1") {
		t.Fatalf("line comment did not use TOML '#': %q", got)
	}
}

func TestFileTypeMappingsPrecedenceAndLiveRefresh(t *testing.T) {
	root := t.TempDir()
	customPath := filepath.Join(root, "app.customcfg")
	if err := os.WriteFile(customPath, []byte("[section]\nkey = \"val\"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	uvPath := filepath.Join(root, "uv.lock")
	if err := os.WriteFile(uvPath, []byte("version = 1\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	h := newHarness(t, &testKernel{Client: core.NewClient()})
	failed, _ := h.app.syntaxRegistry().SetPluginLanguages([]syntax.PluginLanguage{{
		ID:         "pluglang",
		Extensions: []string{".plugonly"},
		Grammar:    []byte(`{"scopeName":"source.pluglang","patterns":[{"match":"key","name":"keyword.control.pluglang"}]}`),
	}})
	if len(failed) != 0 {
		t.Fatal(failed)
	}
	plugPath := filepath.Join(root, "item.plugonly")
	if err := os.WriteFile(plugPath, []byte("key = 1\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	h.open(root)
	p := h.app.project
	h.app.openFile(p, customPath)
	h.app.openFile(p, uvPath)
	h.app.openFile(p, plugPath)
	h.settle()

	docCustom := p.docs.byPath(customPath)
	docUV := p.docs.byPath(uvPath)
	docPlug := p.docs.byPath(plugPath)
	if docCustom.languageID != "" || docCustom.grammar != nil {
		t.Fatalf("expected unmapped customPath initially, got %q", docCustom.languageID)
	}
	if docUV.languageID != "toml" {
		t.Fatalf("expected uv.lock -> toml initially, got %q", docUV.languageID)
	}
	if docPlug.languageID != "pluglang" {
		t.Fatalf("expected item.plugonly -> pluglang initially, got %q", docPlug.languageID)
	}

	src := appFileTypeMappings{app: h.app}
	snap, err := runFileTypeMappingsOp(t, h, src.Load)
	if err != nil {
		t.Fatal(err)
	}
	if snap.HasWorkspace != true || snap.GlobalFingerprint != "missing" || snap.ProjectFingerprint != "missing" {
		t.Fatalf("unexpected initial snapshot: %+v", snap)
	}
	if _, err := os.Stat(snap.ProjectConfigPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("Load created missing project config: %v", err)
	}

	// Global maps *.customcfg -> toml and overrides uv.lock -> ini.
	next := snap
	next.Global = []core.FileTypeMapping{
		{Pattern: "*.customcfg", LanguageID: "toml"},
		{Pattern: "uv.lock", LanguageID: "ini"},
	}
	next.Project = []core.FileTypeMapping{
		{Pattern: "uv.lock", LanguageID: "yaml"},
		{Pattern: "*.plugonly", LanguageID: "json"},
	}
	res, err := runFileTypeMappingsOp(t, h, func(ctx context.Context) (settingswindow.FileTypeMappingsSaveResult, error) {
		return src.Save(ctx, snap, next)
	})
	if err != nil || len(res.Issues) != 0 {
		t.Fatalf("Save failed: err=%v issues=%+v", err, res.Issues)
	}
	if docCustom.languageID != "toml" || docCustom.grammar == nil || docCustom.grammar.Language().ID != "toml" {
		t.Fatalf("customPath did not refresh live to toml: lang=%q grammar=%v", docCustom.languageID, docCustom.grammar)
	}
	if docUV.languageID != "yaml" || docUV.grammar == nil || docUV.grammar.Language().ID != "yaml" {
		t.Fatalf("project override did not beat global for uv.lock: lang=%q", docUV.languageID)
	}
	if docPlug.languageID != "json" || docPlug.grammar == nil || docPlug.grammar.Language().ID != "json" {
		t.Fatalf("project override did not beat plugin language: lang=%q", docPlug.languageID)
	}

	// Verify validation rejects unknown language without writing.
	bad := res.Snapshot
	bad.Global = append(bad.Global, core.FileTypeMapping{Pattern: "*.bad", LanguageID: "no_such_lang"})
	badRes, err := runFileTypeMappingsOp(t, h, func(ctx context.Context) (settingswindow.FileTypeMappingsSaveResult, error) {
		return src.Save(ctx, res.Snapshot, bad)
	})
	if err != nil || len(badRes.Issues) != 1 || badRes.Issues[0].Code != "unknown_language" {
		t.Fatalf("expected unknown_language issue, got err=%v issues=%+v", err, badRes.Issues)
	}

	// Verify external modification conflict is rejected.
	if err := os.WriteFile(res.Snapshot.ProjectConfigPath, []byte(`{"schemaVersion":1,"mappings":[]}`), 0o600); err != nil {
		t.Fatal(err)
	}
	conflictNext := res.Snapshot
	conflictNext.Project = []core.FileTypeMapping{{Pattern: "*.log", LanguageID: "plaintext"}}
	_, err = runFileTypeMappingsOp(t, h, func(ctx context.Context) (settingswindow.FileTypeMappingsSaveResult, error) {
		return src.Save(ctx, res.Snapshot, conflictNext)
	})
	if !errors.Is(err, settingswindow.ErrFileTypeMappingsConflict) {
		t.Fatalf("expected conflict error, got %v", err)
	}
}

func TestFileTypeMappingsStayOutsideInstalledPackage(t *testing.T) {
	if !installedpackagetest.Run(t) {
		return
	}
	preferences, err := store.Open()
	if err != nil {
		t.Fatal(err)
	}
	installedpackagetest.Outside(t, preferences.Dir())
	if err := preferences.Save(settingsFile, settings{Theme: themeDark}); err != nil {
		t.Fatal(err)
	}
	h := newHarnessWithOptions(t, Options{Kernel: &testKernel{Client: core.NewClient()}, Store: preferences, Languages: []string{"en"}})
	root := t.TempDir()
	h.open(root)
	src := appFileTypeMappings{app: h.app}
	snap, err := runFileTypeMappingsOp(t, h, src.Load)
	if err != nil {
		t.Fatal(err)
	}
	next := snap
	next.Global = []core.FileTypeMapping{{Pattern: "*.myconf", LanguageID: "toml"}}
	res, err := runFileTypeMappingsOp(t, h, func(ctx context.Context) (settingswindow.FileTypeMappingsSaveResult, error) {
		return src.Save(ctx, snap, next)
	})
	if err != nil || len(res.Issues) != 0 {
		t.Fatalf("Save failed: err=%v issues=%+v", err, res.Issues)
	}
	installedpackagetest.Outside(t, res.Snapshot.GlobalConfigPath)
}
