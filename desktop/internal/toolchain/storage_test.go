package toolchain

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/configfile"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

func TestSavePinRejectsLinkedConfigurationDirectory(t *testing.T) {
	root, outside := t.TempDir(), t.TempDir()
	linkToolchainDirectory(t, outside, filepath.Join(root, ".lithe"))
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_, _, err := SavePin(ctx, core.NewClient(), root, ".", "dev.example:compiler", &core.ToolchainPin{
		Home: "/fixture/tool", Version: "1.0", Provider: "host:system",
	}, nil)
	if err == nil {
		t.Error("a linked configuration directory was accepted")
	}
	entries, err := os.ReadDir(outside)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 0 {
		t.Fatalf("saving wrote outside the selected workspace: %v", entries)
	}
}

func TestResetAbsentPinDoesNotCreateWorkspaceState(t *testing.T) {
	root := t.TempDir()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if _, _, err := SavePin(ctx, core.NewClient(), root, ".", "dev.example:compiler", nil, nil); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(root, ".lithe")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("an unchanged reset created workspace state: %v", err)
	}
}

func TestLoadRejectsInvalidDormantPinSource(t *testing.T) {
	for _, content := range []string{
		`{"version":1,"version":1,"toolchains":{}}`,
		`{"version":1,"toolchains":{},"unexpected":true}`,
		strings.Repeat(" ", 1048577),
	} {
		t.Run(fmt.Sprintf("source-%d", len(content)), func(t *testing.T) {
			root := t.TempDir()
			path := documentPath(root)
			if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
				t.Fatal(err)
			}
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			if _, err := Load(ctx, core.NewClient(), root, ".", nil, Options{}); err == nil {
				t.Fatal("no installed tools allowed an invalid stored document")
			} else if len(content) > 1048576 {
				if !errors.Is(err, configfile.ErrTooLarge) {
					t.Fatalf("expected bounded native rejection: %v", err)
				}
			} else {
				var rejection *core.MarketplaceRejection
				if !errors.As(err, &rejection) || rejection.Code != "plugin.toolchain.invalidDocument" {
					t.Fatalf("invalid source was not rejected by Core: %v", err)
				}
			}
			if got := string(readExactly(t, path)); got != content {
				t.Fatal("a failed read changed the source")
			}
		})
	}
}

func TestSavePinPreservesIgnoreTextAndOvercomesLaterNegation(t *testing.T) {
	root := t.TempDir()
	ignore := filepath.Join(root, ".lithe", ".gitignore")
	if err := os.MkdirAll(filepath.Dir(ignore), 0o700); err != nil {
		t.Fatal(err)
	}
	before := "# retained\r\n/toolchains/local.json\r\n!/toolchains/local.json"
	if err := os.WriteFile(ignore, []byte(before), 0o640); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if _, _, err := SavePin(ctx, core.NewClient(), root, ".", "dev.example:compiler", &core.ToolchainPin{Home: "/fixture/tool", Version: "1.0", Provider: "host:system"}, nil); err != nil {
		t.Fatal(err)
	}
	if got := string(readExactly(t, ignore)); got != before+"\r\n/toolchains/local.json\r\n" {
		t.Fatalf("ignore source = %q", got)
	}
	if runtime.GOOS != "windows" {
		info, err := os.Stat(ignore)
		if err != nil {
			t.Fatal(err)
		}
		if info.Mode().Perm() != 0o640 {
			t.Fatalf("ignore permissions = %v", info.Mode())
		}
	}
}

func TestSnapshotPinBaselineCannotBeMutatedByCaller(t *testing.T) {
	root := t.TempDir()
	path := documentPath(root)
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	before := []byte(`{"version":1,"toolchains":{}}`)
	if err := os.WriteFile(path, before, 0o600); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	snapshot, err := Load(ctx, core.NewClient(), root, ".", nil, Options{})
	if err != nil {
		t.Fatal(err)
	}
	external := []byte(`{"version":1,"toolchains":{},"pins":{}}`)
	if err := os.WriteFile(path, external, 0o600); err != nil {
		t.Fatal(err)
	}
	snapshot.Baseline = external
	if _, _, err := snapshot.SavePins(ctx, core.NewClient(), []Edit{{Tool: "dev.example:compiler"}}); !errors.Is(err, ErrPinConflict) {
		t.Fatalf("mutated display baseline bypassed capture: %v", err)
	}
	if !bytes.Equal(readExactly(t, path), external) {
		t.Fatal("external source was overwritten")
	}
}

func TestLoadUsesHostPlatformWhenOptionsAreOmitted(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if _, err := Load(ctx, core.NewClient(), t.TempDir(), ".", nil, Options{}); err != nil {
		t.Fatalf("zero-value options did not use the host platform: %v", err)
	}
}
