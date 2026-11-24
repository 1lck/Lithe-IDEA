package pluginservice

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/installedpackagetest"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginpkg"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

func TestUninstallWaitsForPackagePublicationInAnotherProcess(t *testing.T) {
	const pluginID = "dev.lithe.test.publication"
	if !installedpackagetest.Run(t) {
		return
	}
	pluginRoot, err := pluginpkg.DefaultRoot()
	if err != nil {
		t.Fatal(err)
	}
	if root := os.Getenv("LITHE_TEST_PACKAGE_PUBLICATION_ROOT"); root != "" {
		service, err := OpenAnother(core.NewClient(), store.At(filepath.Join(root, "preferences")), pluginRoot)
		if err != nil {
			t.Fatal(err)
		}
		if os.Getenv("LITHE_TEST_PACKAGE_PUBLICATION_STEP") == "busy" {
			ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
			defer cancel()
			err := service.Uninstall(ctx, pluginID, nil, func(context.Context) error {
				t.Fatal("uninstall planned removal while the other process held publication")
				return nil
			})
			if !errors.Is(err, context.DeadlineExceeded) {
				t.Fatalf("contended uninstall = %v, want deadline exceeded", err)
			}
			return
		}
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		if err := service.Uninstall(ctx, pluginID, nil); err != nil {
			t.Fatal(err)
		}
		return
	}

	root := t.TempDir()
	service, err := Open(core.NewClient(), store.At(filepath.Join(root, "preferences")), pluginRoot)
	if err != nil {
		t.Fatal(err)
	}
	installedpackagetest.Outside(t, filepath.Join(pluginRoot, packageChangesLockFile))
	publish := func(version string) {
		t.Helper()
		staging, err := pluginpkg.NewStaging(service.Root)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := pluginpkg.Install(service.Root, pluginID, version, staging); err != nil {
			t.Fatal(err)
		}
	}
	child := func(step string) {
		t.Helper()
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		binary, err := os.Executable()
		if err != nil {
			t.Fatal(err)
		}
		command := exec.CommandContext(ctx, binary, "-test.run=^TestUninstallWaitsForPackagePublicationInAnotherProcess$")
		command.Env = append(os.Environ(), "LITHE_TEST_PACKAGE_PUBLICATION_ROOT="+root, "LITHE_TEST_PACKAGE_PUBLICATION_STEP="+step)
		if output, err := command.CombinedOutput(); err != nil {
			t.Fatalf("uninstall child %s: %v\n%s", step, err, output)
		}
	}

	publish("1.0.0")
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	_, finish, err := service.BeginRuntimeInstallation(ctx, pluginID)
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		if finish != nil {
			if err := finish(); err != nil {
				t.Error(err)
			}
		}
	}()
	// The second process cannot take an uninstall snapshot while publication
	// owns the files. After it retries, its snapshot includes the new version.
	child("busy")
	publish("2.0.0")
	err = finish()
	finish = nil
	if err != nil {
		t.Fatal(err)
	}
	child("released")
	entries, err := pluginpkg.List(service.Root)
	if err != nil || len(entries) != 0 {
		t.Fatalf("installed after uninstall = %v, error = %v", entries, err)
	}
}
