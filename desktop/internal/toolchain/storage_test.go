package toolchain

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
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
	if got := string(readExactly(t, ignore)); got != before+"\r\n/.gitignore\r\n/toolchains/local.json\r\n" {
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

// This integration test asks Git itself which of the files written through the
// native SavePin path are ignored; ordinary toolchain tests need no Git binary.
func TestSavePinIgnoresGeneratedFileWithoutHidingSharedFiles(t *testing.T) {
	git, err := exec.LookPath("git")
	if err != nil {
		t.Skip("git executable not found")
	}
	root, configRoot := t.TempDir(), t.TempDir()
	emptyConfig := filepath.Join(configRoot, "gitconfig")
	if err := os.WriteFile(emptyConfig, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	emptyTemplate := filepath.Join(configRoot, "template")
	if err := os.Mkdir(emptyTemplate, 0o700); err != nil {
		t.Fatal(err)
	}
	// Explicit command environments avoid global mutation and prevent ambient
	// repository, index, config-injection and ignore settings from owning the fixture.
	environment := make([]string, 0, len(os.Environ())+3)
	for _, entry := range os.Environ() {
		if !strings.HasPrefix(strings.ToUpper(entry), "GIT_") {
			environment = append(environment, entry)
		}
	}
	environment = append(environment, "GIT_CONFIG_GLOBAL="+emptyConfig, "GIT_CONFIG_NOSYSTEM=1", "GIT_TERMINAL_PROMPT=0")
	runGit := func(input string, args ...string) string {
		t.Helper()
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		command := exec.CommandContext(ctx, git, append([]string{"-c", "core.excludesFile=" + emptyConfig}, args...)...)
		command.Dir, command.Env = root, environment
		command.Stdin = strings.NewReader(input)
		// init with an empty template and check-ignore do not invoke hooks or
		// child tools. Bound pipe cleanup as well as the local Git process.
		command.WaitDelay = time.Second
		output, err := command.CombinedOutput()
		if err != nil {
			t.Fatalf("git %v: %v\n%s", args, err, output)
		}
		return string(output)
	}
	runGit("", "init", "--quiet", "--template="+emptyTemplate)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if _, _, err := SavePin(ctx, core.NewClient(), root, ".", "dev.example:compiler", &core.ToolchainPin{
		Home: "/fixture/tool", Version: "1.0", Provider: "host:system",
	}, nil); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{".lithe/toolchains/shared.json", ".lithe/nested/.gitignore"} {
		native := filepath.Join(root, filepath.FromSlash(path))
		if err := os.MkdirAll(filepath.Dir(native), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(native, nil, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	paths := ".lithe/.gitignore\x00.lithe/toolchains/local.json\x00.lithe/toolchains/shared.json\x00.lithe/nested/.gitignore\x00"
	if got := runGit(paths, "check-ignore", "--no-index", "--stdin", "-z"); got != ".lithe/.gitignore\x00.lithe/toolchains/local.json\x00" {
		t.Fatalf("Git ignored paths = %q", got)
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
