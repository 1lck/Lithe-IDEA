//go:build windows

package toolchain

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

const nativeToolchainHelper = "LITHE_TEST_NATIVE_TOOLCHAIN"
const nativeToolchainCommand = "lithe-test-vm"

// The copied executable is a synthetic runtime, not an installed tool. Its
// version flags are intentionally not Go testing flags: production probes must
// execute the command they found on PATH without a test-only probe callback.
func TestMain(m *testing.M) {
	if os.Getenv(nativeToolchainHelper) == "1" && filepath.Base(os.Args[0]) == nativeToolchainCommand+".exe" {
		if len(os.Args) != 2 || os.Args[1] != "-version" {
			os.Exit(21)
		}
		fmt.Println("fictional-vm 8.0.1")
		os.Exit(0)
	}
	os.Exit(m.Run())
}

func copyNativeToolchain(t *testing.T, destination string) {
	t.Helper()
	// The fixture never writes the executable; link it when possible so the
	// native loader can reuse the already validated test binary's identity.
	if err := os.Link(os.Args[0], destination); err == nil {
		return
	}
	source, err := os.Open(os.Args[0])
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		if err := source.Close(); err != nil {
			t.Error(err)
		}
	}()
	target, err := os.Create(destination)
	if err != nil {
		t.Fatal(err)
	}
	_, copyErr := io.Copy(target, source)
	closeErr := target.Close()
	if copyErr != nil {
		t.Fatal(copyErr)
	}
	if closeErr != nil {
		t.Fatal(closeErr)
	}
}

func TestToolchainCandidatesUseNativeShellPathsInUserProfiles(t *testing.T) {
	for _, profileName := range []string{"User With Spaces", "用户 甲"} {
		for _, source := range []string{"PATH", "environment"} {
			t.Run(profileName+"/"+source, func(t *testing.T) {
				profile := filepath.Join(t.TempDir(), profileName)
				home := filepath.Join(profile, "Program Files", "Fictional VM")
				bin := filepath.Join(home, "bin")
				workspace := filepath.Join(profile, "Projects", "sample project")
				for _, directory := range []string{bin, workspace} {
					if err := os.MkdirAll(directory, 0o755); err != nil {
						t.Fatal(err)
					}
				}
				copyNativeToolchain(t, filepath.Join(bin, nativeToolchainCommand+".exe"))
				t.Setenv(nativeToolchainHelper, "1")
				t.Setenv("HOME", profile)
				t.Setenv("USERPROFILE", profile)
				// Setenv registers restoration; Unsetenv tests genuine absence.
				t.Setenv("LITHE_TEST_VM_HOME", "")
				if err := os.Unsetenv("LITHE_TEST_VM_HOME"); err != nil {
					t.Fatal(err)
				}
				if source == "PATH" {
					t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
				} else {
					t.Setenv("LITHE_TEST_VM_HOME", home)
				}
				manifest := json.RawMessage(`{
  "schemaVersion":0,"id":"dev.lithe.test.native-toolchain","displayName":"Synthetic VM",
  "version":"1.0.0","pluginAPIVersion":0,"requires":{"toolDefinitions":0},
  "vendor":{"id":"dev.lithe.test","displayName":"Test","signatureRequirement":"publisherPackage"},
  "permissions":[],"toolDefinitions":[{
    "id":"vm","displayName":"Synthetic VM","executableLayouts":[{"path":"bin/lithe-test-vm.exe"}],
    "executables":[
      {"id":"shell","kind":"command","command":"lithe-test-vm"},
      {"id":"environment","kind":"environment","variable":"LITHE_TEST_VM_HOME","path":"bin/lithe-test-vm.exe"},
      {"id":"installed","kind":"toolchain","scope":"installed"}
    ],
    "version":{"arguments":["-version"],"pattern":"fictional-vm (\\d+(?:\\.\\d+)*)"},
    "commands":["lithe-test-vm"],"homeVariable":"LITHE_TEST_VM_HOME",
    "discovery":[{"root":{"kind":"home"},"pattern":"managed/*"}],
    "launch":["${executable}","${arguments}"]
  }]
}`)
				ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
				defer cancel()
				// Home, Environment, Lookup and Probe all use the native defaults.
				// The private catalog keeps existing user configuration out of the test.
				snapshot, err := Load(ctx, core.NewClient(), workspace, ".", []json.RawMessage{manifest}, Options{
					GlobalRoot: filepath.Join(profile, "Lithe data"),
				})
				if err != nil {
					t.Fatal(err)
				}
				if len(snapshot.Tools) != 1 || len(snapshot.Tools[0].Installations) != 1 {
					t.Fatalf("native shell installation missing: %+v", snapshot.Tools)
				}
				installation := snapshot.Tools[0].Installations[0]
				if filepath.Clean(installation.Home) != canonical(t, home) || installation.Version != "8.0.1" || installation.Provider != "host:shell" {
					t.Fatalf("installation = %+v, want native %s home %s", installation, source, home)
				}
			})
		}
	}
}
