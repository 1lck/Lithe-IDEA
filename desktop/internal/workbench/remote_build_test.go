package workbench

import (
	"context"
	"encoding/json"
	"errors"
	"path/filepath"
	"slices"
	"sync"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
)

func TestRemoteBuildExecutionUsesScopedWorkingDirectory(t *testing.T) {
	h, host, _, _ := remoteWorkspaceHarness(t)
	p := h.openRemoteTestProject(t)
	connection := p.remote.binding.CaptureConnection()
	if connection == nil {
		t.Fatal("the project did not capture the host connection")
	}
	host.setRuns(func(runs *remoteHostRuns) {
		zero := 0
		runs.exit = core.RemoteProcessExit{ExitCode: &zero}
	})
	ctx, cancel := context.WithTimeout(connection.Context(p.ctx), 5*time.Second)
	defer cancel()
	directory := filepath.Join(p.root, "nested", "src")
	_, err := h.app.captureWorkspaceBuildProcess(ctx, p, buildExecution{Executable: "fixture-tool"}, nil, directory, nil, false, func(string) {})
	if err != nil {
		t.Fatal(err)
	}
	opens, _, _, _, _ := host.hostRuns()
	want := core.RemoteScopedDirectory{Root: remoteTestFolder, Path: "nested/src"}
	if len(opens) != 1 || opens[0].Cwd != "" || opens[0].ScopedCwd == nil || *opens[0].ScopedCwd != want {
		t.Fatalf("expected one scoped launch in %+v, got %+v", want, opens)
	}
}

type remoteBuildKernel struct {
	*remoteHostKernel
	firstStarted chan struct{}
	releaseFirst chan struct{}
}

func (k *remoteBuildKernel) ReadWorkspaceConfiguration(ctx context.Context, path string, _ int64) (*string, error) {
	binding := core.RemoteWorkspaceOf(ctx)
	if binding == nil || path != buildTeamOptionsFile {
		return nil, errors.New("team build preferences must come from the remote workspace")
	}
	document := `{"version":1,"systems":{},"ignoredPaths":["remote-vendor/"]}`
	return &document, nil
}

func (k *remoteBuildKernel) ResolveStoredBuildOptions(ctx context.Context, team, local json.RawMessage) (core.BuildStoredOptions, error) {
	if core.RemoteWorkspaceOf(ctx) != nil {
		return core.BuildStoredOptions{}, errors.New("merging build preferences must run on the client")
	}
	return k.Client.ResolveStoredBuildOptions(ctx, team, local)
}

func (k *remoteBuildKernel) DetectBuildSystemsWithOptions(ctx context.Context, root string, manifests []json.RawMessage, options core.BuildDetectOptions) (core.BuildDetection, error) {
	binding := core.RemoteWorkspaceOf(ctx)
	if binding == nil || root != binding.LocalRoot() || len(manifests) != 1 || !slices.Equal(options.IgnoredPaths, []string{"remote-vendor/"}) {
		return core.BuildDetection{}, errors.New("detection did not receive the remote binding, plugin or team preferences")
	}
	session := binding.SessionID()
	if session == "session-1" {
		close(k.firstStarted)
		select {
		case <-ctx.Done():
			return core.BuildDetection{}, ctx.Err()
		case <-k.releaseFirst:
		}
	}
	return core.BuildDetection{Instances: []core.BuildInstance{{
		ID: session, PluginID: hotBuildPluginID, BuildSystemID: "hot-fixture", Root: ".",
		ModelSource: "static", Model: json.RawMessage(`{"projects":[{"id":"app","name":"Remote App"}]}`),
	}}}, nil
}

func TestRemoteBuildDetectionUsesHostOptionsAndDiscardsOldSession(t *testing.T) {
	h, host, timers, _ := remoteWorkspaceHarness(t)
	p := h.openRemoteTestProject(t)

	kernel := &remoteBuildKernel{
		remoteHostKernel: host,
		firstStarted:     make(chan struct{}),
		releaseFirst:     make(chan struct{}),
	}
	releaseFirst := sync.OnceFunc(func() { close(kernel.releaseFirst) })
	defer releaseFirst()
	h.app.kernel = kernel
	service, err := pluginservice.Open(kernel, h.store, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(service.Contexts.CloseAll)
	h.app.plugins = service

	// Installing starts detection. Reconnect while its first answer is held, then
	// deliver that answer after the replacement connection's model has been published.
	h.app.installPluginFromFile(writeHotBuildPluginArchive(t, hotBuildPluginID, hotBuildPluginManifest), approvingPluginInstall(t))
	awaitValueWithin(t, h, kernelCallTimeout, kernel.firstStarted, "first remote build detection")
	h.app.post(func(a *App) { a.loseRemote(p, "session-1", errRemoteSessionClosed) })
	h.await("the scheduled reconnection", func() bool {
		return p.remote.session == "" && timers.live() == 1
	})
	// Drive only the reconnect timer so the first detection can arrive after the new model.
	timers.take(t).run()
	h.await("replacement connection's build model", func() bool {
		return !p.build.loading && len(p.build.instances) == 1 && p.build.instances[0].ID == "session-2"
	})
	releaseFirst()
	h.settle()
	if len(p.build.instances) != 1 || p.build.instances[0].ID != "session-2" {
		t.Fatalf("old connection replaced the build instances: %+v", p.build.instances)
	}
	instance := p.build.instances[0]
	if !instance.modelLoaded || len(instance.Model.Projects) != 1 || instance.Model.Projects[0].Name != "Remote App" {
		t.Fatalf("the remote static model was not loaded: %+v", instance)
	}
	if p.runConfigs.generation == 0 || p.runConfigs.loading || p.runConfigs.failure != "" {
		t.Fatalf("remote build detection did not resolve run configurations: generation %d, loading %v, failure %q",
			p.runConfigs.generation, p.runConfigs.loading, p.runConfigs.failure)
	}
}
