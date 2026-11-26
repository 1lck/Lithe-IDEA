package workbench

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/remoteserver"
)

// This opt-in integration uses the actual selected daemon and official CLI, including
// lifecycle commands, the workspace bind mount, checked server upload and remote file I/O.
func TestRemoteDevcontainerActualRuntimeLifecycle(t *testing.T) {
	contextName := os.Getenv("LITHE_TEST_DEVCONTAINER_CONTEXT")
	image := os.Getenv("LITHE_TEST_DEVCONTAINER_IMAGE")
	if contextName == "" || image == "" {
		t.Skip("set LITHE_TEST_DEVCONTAINER_CONTEXT and LITHE_TEST_DEVCONTAINER_IMAGE for real container creation")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 120*time.Second)
	defer cancel()
	client := core.NewClient()
	runtimes, err := client.RemoteContainerRuntimes(ctx)
	if err != nil {
		t.Fatal(err)
	}
	var target *core.ContainerRuntimeTarget
	for _, runtime := range runtimes.Runtimes {
		if runtime.Context == contextName && runtime.WSL == "" && runtime.Available {
			copy := runtime.ContainerRuntimeTarget
			target = &copy
		}
	}
	if target == nil {
		t.Fatal("the explicitly selected actual runtime was not discovered as ready")
	}
	bundle, err := remoteserver.Resolve(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	folder := t.TempDir()
	// Even a failed up may have created a container. Only the unique temporary workspace's
	// label is cleaned; pre-existing containers and images are never changed.
	t.Cleanup(func() {
		cleanup, done := context.WithTimeout(context.Background(), 15*time.Second)
		defer done()
		output, err := exec.CommandContext(cleanup, "docker", "--context", contextName, "ps", "-aq", "--filter", "label=devcontainer.local_folder="+folder).Output()
		if err != nil {
			t.Errorf("list this test's containers for cleanup: %v", err)
			return
		}
		if ids := strings.Fields(string(output)); len(ids) > 0 {
			args := append([]string{"--context", contextName, "rm", "-f"}, ids...)
			if output, err := exec.CommandContext(cleanup, "docker", args...).CombinedOutput(); err != nil {
				t.Errorf("remove this test's containers: %s, %v", output, err)
			}
		}
	})
	prepared, err := client.RemoteDevcontainerPrepare(ctx, core.DevcontainerForm{
		Name: "Lithe integration", Image: image,
		PostCreateCommand: "printf devcontainer-lifecycle-ok > .lithe-devcontainer-created",
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := writeRemoteDevcontainerConfig(ctx, folder, prepared); err != nil {
		t.Fatal(err)
	}
	configs, err := client.RemoteDevcontainerRuntimeConfigs(ctx, folder, target)
	if err != nil || len(configs.Configs) != 1 {
		t.Fatalf("reread = %+v, %v", configs, err)
	}
	up, err := client.RemoteDevcontainerUp(ctx, core.DevcontainerUpRequest{
		Folder: folder, Config: configs.Configs[0].Path, Engine: target.Engine,
		Runtime: target, ProjectCodeAllowed: true,
	}, nil)
	if err != nil || up.Container == nil {
		t.Fatalf("actual up = %+v, %v", up, err)
	}
	marker, err := os.ReadFile(filepath.Join(folder, ".lithe-devcontainer-created"))
	if err != nil || string(marker) != "devcontainer-lifecycle-ok" {
		t.Fatalf("lifecycle did not write through the real workspace mount: %q, %v", marker, err)
	}
	connection := up.Container.Connection()
	if connection.Context != contextName {
		t.Fatal("build lost its selected Docker context before connecting")
	}
	request := core.RemoteConnectRequest{Container: &connection, ServerVersion: bundle.Version}
	for _, build := range bundle.Builds {
		request.Servers = append(request.Servers, core.RemoteServerBuild{Target: build.Target, Path: build.Path, SHA256: build.SHA256})
	}
	connected, err := client.RemoteConnect(ctx, request)
	if err != nil || connected.Status != core.RemoteProbeConnected || connected.Session == nil {
		t.Fatalf("actual connection = %+v, %v", connected, err)
	}
	t.Cleanup(func() {
		cleanup, done := context.WithTimeout(context.Background(), 10*time.Second)
		defer done()
		if _, err := client.RemoteDisconnect(cleanup, connected.Session.ID, core.RemoteCloseEnd); err != nil {
			t.Errorf("disconnect this test's remote server: %v", err)
		}
	})
	path := strings.TrimRight(up.Container.WorkspaceFolder, "/") + "/.lithe-devcontainer-created"
	read, _, err := client.RemoteReadFile(ctx, connected.Session.ID, path)
	if err != nil || string(read) != string(marker) {
		t.Fatalf("remote workspace read = %q, %v", read, err)
	}
	t.Logf("actual %s build, lifecycle command, selected-context connection and remote workspace read passed", contextName)
}
