package pluginhost

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"
)

// launchPackage creates a package holding an executable program and a data file.
func launchPackage(t *testing.T) string {
	t.Helper()
	root := writePackage(t, map[string]string{
		"bin/server":  "binary",
		"lib/data.js": "code",
		"lib/main.js": "entry",
	})
	if err := os.Chmod(filepath.Join(root, "bin", "server"), 0o755); err != nil {
		t.Fatal(err)
	}
	return root
}

func TestVerifyLaunchPackaged(t *testing.T) {
	root := launchPackage(t)
	resolved, err := VerifyLaunch(root, Launch{
		Kind:     LaunchPackaged,
		Path:     "bin/server",
		Required: []string{"lib/data.js"},
	})
	if err != nil {
		t.Fatalf("verify: %v", err)
	}
	if resolved.Executable != filepath.Join(root, "bin", "server") {
		t.Fatalf("executable = %q", resolved.Executable)
	}
	if len(resolved.Required) != 1 || resolved.Required[0] != filepath.Join(root, "lib", "data.js") {
		t.Fatalf("required = %v", resolved.Required)
	}
	if resolved.Entry != "" || resolved.Runtime != "" {
		t.Fatalf("resolved = %+v", resolved)
	}
}

func TestVerifyLaunchPackagedRefusals(t *testing.T) {
	root := launchPackage(t)
	cases := map[string]Launch{
		"no program":       {Kind: LaunchPackaged},
		"missing program":  {Kind: LaunchPackaged, Path: "bin/absent"},
		"not executable":   {Kind: LaunchPackaged, Path: "lib/data.js"},
		"escaping program": {Kind: LaunchPackaged, Path: "../server"},
		"missing required": {Kind: LaunchPackaged, Path: "bin/server", Required: []string{"lib/absent"}},
		"unknown kind":     {Kind: "container"},
	}
	for name, launch := range cases {
		t.Run(name, func(t *testing.T) {
			if _, err := VerifyLaunch(root, launch); !errors.Is(err, ErrPackagePath) && !errors.Is(err, ErrNotExecutable) {
				t.Fatalf("err = %v", err)
			}
		})
	}
}

func TestVerifyLaunchRuntime(t *testing.T) {
	root := launchPackage(t)
	resolved, err := VerifyLaunch(root, Launch{
		Kind:            LaunchRuntime,
		PackagedRuntime: "bin/server",
		Entry:           "lib/main.js",
		Required:        []string{"lib/data.js"},
	})
	if err != nil {
		t.Fatalf("verify: %v", err)
	}
	if resolved.Runtime != filepath.Join(root, "bin", "server") {
		t.Fatalf("runtime = %q", resolved.Runtime)
	}
	if resolved.Entry != filepath.Join(root, "lib", "main.js") {
		t.Fatalf("entry = %q", resolved.Entry)
	}
	if len(resolved.Required) != 1 {
		t.Fatalf("required = %v", resolved.Required)
	}
}

func TestVerifyLaunchRuntimeWithoutEntry(t *testing.T) {
	root := launchPackage(t)
	resolved, err := VerifyLaunch(root, Launch{Kind: LaunchRuntime, PackagedRuntime: "bin/server"})
	if err != nil {
		t.Fatalf("verify: %v", err)
	}
	if resolved.Entry != "" {
		t.Fatalf("entry = %q", resolved.Entry)
	}
}

func TestVerifyLaunchRuntimeRefusesMissingRuntime(t *testing.T) {
	root := launchPackage(t)
	if _, err := VerifyLaunch(root, Launch{Kind: LaunchRuntime, Entry: "lib/main.js"}); !errors.Is(err, ErrPackagePath) {
		t.Fatalf("err = %v", err)
	}
}

func TestVerifyLaunchRefusesSymlinkedProgram(t *testing.T) {
	root := launchPackage(t)
	outside := filepath.Join(t.TempDir(), "outside")
	if err := os.WriteFile(outside, []byte("binary"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(root, "linked")); err != nil {
		t.Skipf("this platform cannot create symbolic links: %v", err)
	}
	if _, err := VerifyLaunch(root, Launch{Kind: LaunchPackaged, Path: "linked"}); !errors.Is(err, ErrPackageSymlink) {
		t.Fatalf("err = %v", err)
	}
}

func TestResolveCommand(t *testing.T) {
	lookup := func(name string) (string, error) {
		if name == "gopls" {
			return "/usr/local/bin/gopls", nil
		}
		return "", errors.New("not found")
	}
	// The first available command wins, in the order the plan offers them.
	if path, err := ResolveCommand([]string{"pylsp", "gopls"}, lookup); err != nil || path != "/usr/local/bin/gopls" {
		t.Fatalf("path = %q, err = %v", path, err)
	}
	if _, err := ResolveCommand([]string{"pylsp"}, lookup); !errors.Is(err, ErrPackagePath) {
		t.Fatalf("err = %v", err)
	}
	// The contract lists bare command names; a path would name a file the host never
	// checked.
	if _, err := ResolveCommand([]string{"/bin/sh", `..\sh`}, lookup); !errors.Is(err, ErrPackagePath) {
		t.Fatalf("err = %v", err)
	}
	if _, err := ResolveCommand([]string{"gopls"}, nil); !errors.Is(err, ErrPackagePath) {
		t.Fatalf("err = %v", err)
	}
	if _, err := ResolveCommand(nil, lookup); !errors.Is(err, ErrPackagePath) {
		t.Fatalf("err = %v", err)
	}
}

func TestVerifyLaunchSystemCommand(t *testing.T) {
	root := launchPackage(t)
	resolved, err := VerifyLaunch(root, Launch{
		Kind:     LaunchSystemCommand,
		Commands: []string{"gopls"},
		Required: []string{"lib/data.js"},
	})
	if err != nil {
		t.Fatalf("verify: %v", err)
	}
	// The host resolves the command itself, so verification leaves it empty and only
	// proves the package files the launch needs.
	if resolved.Executable != "" || resolved.Runtime != "" {
		t.Fatalf("resolved = %+v", resolved)
	}
	if len(resolved.Required) != 1 || resolved.Required[0] != filepath.Join(root, "lib", "data.js") {
		t.Fatalf("required = %v", resolved.Required)
	}
	// Required package paths are still verified.
	if _, err := VerifyLaunch(root, Launch{Kind: LaunchSystemCommand, Required: []string{"lib/absent"}}); !errors.Is(err, ErrPackagePath) {
		t.Fatalf("err = %v", err)
	}
}

func TestGrantServicesIntersects(t *testing.T) {
	services := NewServices()
	for _, method := range []string{MethodPrefix + "workspace/stat", MethodPrefix + "documents/list"} {
		if err := services.Register(method, func(context.Context, json.RawMessage) (json.RawMessage, *Failure) {
			return json.RawMessage(`{}`), nil
		}); err != nil {
			t.Fatal(err)
		}
	}
	granted := GrantServices([]string{
		MethodPrefix + "workspace/stat",
		MethodPrefix + "editor/applyEdits",
	}, services)
	if len(granted) != 1 || granted[0] != MethodPrefix+"workspace/stat" {
		t.Fatalf("granted = %v", granted)
	}
	if GrantServices([]string{MethodPrefix + "editor/applyEdits"}, services) != nil {
		t.Fatal("an unregistered method was granted")
	}
	if GrantServices(nil, services) != nil {
		t.Fatal("an empty request granted something")
	}
	if GrantServices([]string{MethodPrefix + "workspace/stat"}, nil) != nil {
		t.Fatal("a nil registry granted something")
	}
}

func TestVerifyLaunchAcceptsHostRuntimeWithPackagedEntry(t *testing.T) {
	root := writePackage(t, map[string]string{"provider/main.jar": "jar"})
	resolved, err := VerifyLaunch(root, Launch{
		Kind:  LaunchRuntime,
		Tool:  "java",
		Entry: "provider/main.jar",
	})
	if err != nil {
		t.Fatalf("verify: %v", err)
	}
	if resolved.Runtime != "" || resolved.Entry != filepath.Join(root, "provider", "main.jar") {
		t.Fatalf("resolved = %+v", resolved)
	}
}
