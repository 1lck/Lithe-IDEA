package workbench

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
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
	res, err := client.ResolveDirectoryPresentation(ctx, rules, nil, []string{"target"}, false, []string{
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
