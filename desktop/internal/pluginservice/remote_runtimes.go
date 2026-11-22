package pluginservice

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"fmt"
	"path"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginbackend"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginpkg"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginruntime"
)

type remoteRuntimeKernel interface {
	PlanManagedRuntimes(context.Context, json.RawMessage, core.ManagedRuntimePlatform) (core.ManagedRuntimePlan, error)
	VerifyMarketplaceRemoteVariant(context.Context, core.MarketplaceVariantReview) (json.RawMessage, error)
	LookupRemoteManagedRuntime(context.Context, core.RemoteManagedRuntimeLayout) (*core.RemoteManagedRuntimePaths, error)
	CreateRemoteRuntimeStaging(context.Context, string) (string, error)
	ReleaseRemoteRunDirectory(context.Context, string) error
	UploadRemotePluginFile(context.Context, string, string, string, uint32) error
	CommitRemoteManagedRuntime(context.Context, core.RemoteManagedRuntimeLayout, string) (*core.RemoteManagedRuntimePaths, error)
}

var _ remoteRuntimeKernel = (*core.Client)(nil)

// RemoteTools supplies the installations approved for processes on this attachment.
func (s *Service) RemoteTools(ctx context.Context, installed pluginpkg.Installed, manifest json.RawMessage, connection *core.RemoteWorkspaceConnection, platform core.RemotePlatform) (map[string]pluginbackend.ToolExecutable, error) {
	environment, err := s.prepareRemoteRuntimes(ctx, installed, manifest, connection, platform, nil)
	return environment.Tools, err
}

// prepareRemoteRuntimes uses the remote platform's approved pinned artifacts.
// The local compatibility hook is for local installations. The remote host
// verifies the pinned archive, runtime home and executable before supplying
// these native facts to the plugin's launch resolver.
func (s *Service) prepareRemoteRuntimes(ctx context.Context, installed pluginpkg.Installed, manifest json.RawMessage, connection *core.RemoteWorkspaceConnection, platform core.RemotePlatform, progress func(pluginruntime.Progress)) (RuntimeEnvironment, error) {
	if !HasManagedRuntimes(manifest) {
		return RuntimeEnvironment{}, nil
	}
	kernel, ok := s.kernel.(remoteRuntimeKernel)
	if !ok {
		return RuntimeEnvironment{}, fmt.Errorf("%w: remote managed runtime service unavailable", ErrAssembly)
	}
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	stopDetach := connection.AfterDetach(cancel)
	defer stopDetach()
	ctx = connection.Context(ctx)

	approval, found, err := s.Manager.Approval(installed.ID, installed.Version)
	if err != nil {
		return RuntimeEnvironment{}, err
	}
	if !found {
		return RuntimeEnvironment{}, &core.MarketplaceRejection{
			Code: "plugin.remote.approvalRequired", Message: "The remote runtime requires an approved plugin release.",
		}
	}
	// Revalidate the programs from the exact manifest used for this launch.
	// A modified installed manifest cannot introduce a new archive or tool.
	local := core.WithoutRemoteWorkspace(ctx)
	approved, err := kernel.VerifyMarketplaceRemoteVariant(local, core.MarketplaceVariantReview{
		InstalledManifest: manifest, VariantManifest: manifest, PluginID: installed.ID, Version: installed.Version,
		ApprovedPrograms: approval.ApprovedPrograms, HostCapabilities: s.Capabilities().Clone(),
	})
	if err != nil {
		return RuntimeEnvironment{}, err
	}
	plan, err := kernel.PlanManagedRuntimes(local, approved, core.ManagedRuntimePlatform(platform))
	if err != nil {
		return RuntimeEnvironment{}, err
	}
	environment := RuntimeEnvironment{
		Runtimes: make(map[string]core.ManagedRuntimeInstallation, len(plan.Dependencies)),
		Tools:    make(map[string]pluginbackend.ToolExecutable),
		Facts:    make(map[string]RuntimeTool),
	}
	for _, dependency := range plan.Dependencies {
		installation, err := s.prepareRemoteRuntime(ctx, kernel, installed, dependency, progress)
		if err != nil {
			return RuntimeEnvironment{}, err
		}
		environment.Runtimes[dependency.ID] = core.ManagedRuntimeInstallation{
			ID: dependency.ID, Version: dependency.Version, Home: installation.Home,
		}
		if dependency.Tool != "" {
			environment.Tools[dependency.Tool] = pluginbackend.ToolExecutable{Path: installation.Executable, Home: installation.Home}
			environment.Facts[dependency.Tool] = RuntimeTool{
				Executable: installation.Executable, Home: installation.Home, Version: dependency.Version,
			}
		}
	}
	return environment, ctx.Err()
}

func (s *Service) prepareRemoteRuntime(ctx context.Context, kernel remoteRuntimeKernel, installed pluginpkg.Installed, dependency core.ManagedRuntimeDependency, progress func(pluginruntime.Progress)) (*core.RemoteManagedRuntimePaths, error) {
	report := func(phase string) {
		if progress != nil {
			progress(pluginruntime.Progress{ID: dependency.ID, Phase: phase})
		}
	}
	report("checking")
	layout := core.RemoteManagedRuntimeLayout{
		Key:           core.RemotePluginDeployment{PluginID: installed.ID, Version: installed.Version, SHA256: dependency.CacheKey},
		ArchiveSHA256: dependency.SHA256, Archive: dependency.Archive,
		StripPrefix: dependency.StripPrefix, Home: dependency.Home, Executable: dependency.Executable,
	}
	installation, err := kernel.LookupRemoteManagedRuntime(ctx, layout)
	if err != nil {
		return nil, err
	}
	if installation != nil {
		report("ready")
		return installation, nil
	}
	manager := pluginruntime.Manager{Downloader: s.RuntimeDownloader}
	download, cleanup, err := manager.DownloadArchive(core.WithoutRemoteWorkspace(ctx), runtimeArtifact(dependency), progress)
	if err != nil {
		return nil, err
	}
	defer func() { s.recordDeploymentCleanup(ctx, cleanup()) }()

	id := "runtime-" + rand.Text()
	defer func() {
		cleanup, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
		defer cancel()
		s.recordDeploymentCleanup(ctx, kernel.ReleaseRemoteRunDirectory(cleanup, id))
	}()
	staging, err := kernel.CreateRemoteRuntimeStaging(ctx, id)
	if err != nil {
		return nil, err
	}
	uploadCtx := ctx
	if progress != nil {
		uploadCtx = core.WithRemoteStages(ctx, func(stage core.RemoteStage) {
			if stage.Stage == core.RemoteStageUploading {
				progress(pluginruntime.Progress{ID: dependency.ID, Phase: "uploading",
					Received: int64(stage.SentBytes), Total: int64(stage.TotalBytes)})
			}
		})
	}
	if err := kernel.UploadRemotePluginFile(uploadCtx, download.Path(), path.Join(staging, "archive"), dependency.SHA256, 0o400); err != nil {
		return nil, err
	}
	report("extracting")
	installation, err = kernel.CommitRemoteManagedRuntime(ctx, layout, id)
	if err != nil {
		return nil, err
	}
	report("ready")
	return installation, nil
}
