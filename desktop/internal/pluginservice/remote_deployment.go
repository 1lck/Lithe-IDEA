package pluginservice

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path"
	"path/filepath"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/marketplace"
	"github.com/1lck/Lithe-IDEA/desktop/internal/plugininstall"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginpkg"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginruntime"
	"github.com/1lck/Lithe-IDEA/desktop/internal/plugintrust"
)

type remoteDeploymentKernel interface {
	SelectMarketplaceRemoteVariant(context.Context, core.MarketplaceRemoteVariantRequest) (core.MarketplaceAvailability, error)
	VerifyMarketplaceRemoteVariant(context.Context, core.MarketplaceVariantReview) (json.RawMessage, error)
	PlanMarketplaceRemoteDeployment(context.Context, core.MarketplaceDeploymentRequest) (core.MarketplaceDeployment, error)
	LookupRemotePluginDeployment(context.Context, core.RemotePluginDeployment) (string, error)
	CreateRemoteRuntimeStaging(context.Context, string) (string, error)
	ReleaseRemoteRunDirectory(context.Context, string) error
	CreateRemotePluginDirectory(context.Context, string) error
	UploadRemotePluginFile(context.Context, string, string, string, uint32) error
	CommitRemotePluginDeployment(context.Context, core.RemotePluginDeployment, string) (string, error)
}

var _ remoteDeploymentKernel = (*core.Client)(nil)

// SweepRemoteDeployments retains the current installed version of each plugin,
// including disabled ones. The host protects older versions with active leases.
func (s *Service) SweepRemoteDeployments(ctx context.Context) error {
	kernel, ok := s.kernel.(interface {
		SweepRemotePluginDeployments(context.Context, []core.RemoteInstalledPluginVersion) error
	})
	if !ok {
		return &core.Error{Code: core.CodeNotSupported, Message: "Remote plugin deployment is unavailable."}
	}
	packages, err := s.CurrentInstalled(ctx)
	if err != nil {
		return err
	}
	installed := make([]core.RemoteInstalledPluginVersion, 0, len(packages))
	for _, pkg := range packages {
		installed = append(installed, core.RemoteInstalledPluginVersion{PluginID: pkg.Installed.ID, Version: pkg.Installed.Version})
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	return kernel.SweepRemotePluginDeployments(ctx, installed)
}

// RemoteDeployment binds an installed release to the target captured for a
// process launch. The runner asks for its files only after Core plans placement.
func (s *Service) RemoteDeployment(installed pluginpkg.Installed, manifest json.RawMessage, target core.RemotePlatform, progress func(pluginruntime.Progress)) func(context.Context, []string) (string, error) {
	return func(ctx context.Context, required []string) (string, error) {
		return s.prepareRemoteDeployment(ctx, installed, manifest, target, required, progress)
	}
}

func (s *Service) prepareRemoteDeployment(ctx context.Context, installed pluginpkg.Installed, manifest json.RawMessage, target core.RemotePlatform, required []string, progress func(pluginruntime.Progress)) (directory string, err error) {
	kernel, ok := s.kernel.(remoteDeploymentKernel)
	if !ok {
		return "", &core.Error{Code: core.CodeNotSupported, Message: "Remote plugin deployment is unavailable."}
	}
	approval, found, err := s.Manager.Approval(installed.ID, installed.Version)
	if err != nil {
		return "", err
	}
	local := ArchivePlatform()
	useInstalled := found && approval.SealedTreeSHA256 != "" && local.OS == target.OS && local.Arch == target.Arch
	capabilities := s.Capabilities().Clone()
	review := core.MarketplaceVariantReview{
		InstalledManifest: manifest, PluginID: installed.ID, Version: installed.Version,
		ApprovedPrograms: approval.ApprovedPrograms, HostCapabilities: capabilities,
	}
	request := core.MarketplaceDeploymentRequest{
		Manifest: manifest, Target: target, RequiredPaths: required,
	}
	var selection core.MarketplaceAvailability
	if useInstalled {
		request.InstalledTreeSHA256 = approval.SealedTreeSHA256
	} else {
		if !found || approval.Source != plugintrust.Marketplace || approval.ArchiveSHA256 == "" || approval.MarketplaceIndexURL == "" {
			return "", &core.MarketplaceRejection{
				Code: "plugin.remote.variantUnavailable", Message: "No approved package is available for the workspace host.",
			}
		}
		index := marketplace.New(nil, s.RuntimeDownloader.HTTPClient())
		selection, err = index.FetchRemoteVariant(core.WithoutRemoteWorkspace(ctx), approval.MarketplaceIndexURL, core.MarketplaceRemoteVariantRequest{
			PluginID: installed.ID, Version: installed.Version, InstalledPlatform: marketplace.CurrentPlatform(),
			InstalledSHA256: approval.ArchiveSHA256, Repository: approval.MarketplaceRepository,
			Target: target, HostCapabilities: capabilities,
		}, kernel.SelectMarketplaceRemoteVariant)
		if err != nil {
			return "", err
		}
		request.ArchiveSHA256 = selection.SHA256
	}
	plan, err := kernel.PlanMarketplaceRemoteDeployment(ctx, request)
	if err != nil {
		return "", err
	}
	key := core.RemotePluginDeployment{PluginID: installed.ID, Version: installed.Version, SHA256: plan.SHA256}
	var variant plugininstall.RemoteVariant
	defer func() {
		if variant.Directory != "" {
			s.recordDeploymentCleanup(ctx, os.RemoveAll(variant.Directory))
		}
	}()
	if useInstalled {
		// Verify the installation before using either its bytes or an existing
		// deployment. Its manifest and mode bits may have changed on disk.
		variant, err = plugininstall.SnapshotInstalledVariant(ctx, installed.Path, approval.SealedTreeSHA256, review, kernel.VerifyMarketplaceRemoteVariant)
		if err != nil {
			return "", err
		}
	}

	// The lookup follows provenance validation so a package under the same
	// version cannot claim another archive's deployment.
	directory, err = kernel.LookupRemotePluginDeployment(ctx, key)
	if err != nil || directory != "" {
		return directory, err
	}

	if !useInstalled {
		variant, err = s.extractRemoteVariant(ctx, kernel, selection, review, progress)
		if err != nil {
			return "", err
		}
	}
	request.ArchiveFiles = make([]string, 0, len(variant.Files))
	for _, file := range variant.Files {
		request.ArchiveFiles = append(request.ArchiveFiles, file.Path)
	}
	selected, err := kernel.PlanMarketplaceRemoteDeployment(ctx, request)
	if err != nil {
		return "", err
	}
	if selected.SHA256 != key.SHA256 || len(selected.Paths) == 0 {
		return "", errors.New("the deployment plan changed after package verification")
	}
	return s.publishRemoteDeployment(ctx, kernel, key, selected.Paths, variant)
}

func (s *Service) extractRemoteVariant(ctx context.Context, kernel remoteDeploymentKernel, selection core.MarketplaceAvailability, review core.MarketplaceVariantReview, progress func(pluginruntime.Progress)) (plugininstall.RemoteVariant, error) {
	var variant plugininstall.RemoteVariant
	consume := func(archivePath string) error {
		var err error
		variant, err = plugininstall.ExtractRemoteVariant(ctx, archivePath, selection.SHA256, "", review, kernel.VerifyMarketplaceRemoteVariant)
		return err
	}
	cache, cacheErr := marketplace.NewRemoteArchiveCache()
	cacheAvailable := cacheErr == nil
	if cacheAvailable {
		var used bool
		used, cacheErr = cache.Read(ctx, selection.SHA256, consume)
		if variant.Directory != "" {
			s.recordDeploymentCleanup(ctx, cacheErr)
			return variant, nil
		}
		// A checksum failure is repairable by downloading again. A different
		// manifest or review failure will recur for that same digest.
		if used && !errors.Is(cacheErr, plugininstall.ErrArchiveDigest) && !errors.Is(cacheErr, os.ErrNotExist) {
			return variant, cacheErr
		}
	}
	if err := ctx.Err(); err != nil {
		return variant, err
	}
	if cacheErr != nil {
		s.recordDeploymentCleanup(ctx, cacheErr)
	}

	downloads := marketplace.NewArchiveSession(s.RuntimeDownloader)
	defer func() { s.recordDeploymentCleanup(ctx, downloads.Close()) }()
	archive, err := downloads.Download(ctx, selection, func(update marketplace.ArchiveProgress) {
		if progress != nil {
			progress(pluginruntime.Progress{ID: review.PluginID, Phase: "downloading", Received: update.Received, Total: update.Total})
		}
	})
	if err != nil {
		return variant, err
	}
	defer func() { s.recordDeploymentCleanup(ctx, archive.Discard()) }()
	if err := consume(archive.Path()); err != nil {
		return variant, err
	}
	if cacheAvailable {
		s.recordDeploymentCleanup(ctx, cache.Store(ctx, selection.SHA256, archive))
	}
	return variant, nil
}

func (s *Service) publishRemoteDeployment(ctx context.Context, kernel remoteDeploymentKernel, key core.RemotePluginDeployment, required []string, variant plugininstall.RemoteVariant) (string, error) {
	files := make(map[string]pluginpkg.File, len(variant.Files))
	for _, file := range variant.Files {
		files[file.Path] = file
	}
	for _, name := range required {
		if _, found := files[name]; !found {
			return "", &core.MarketplaceRejection{
				Code: "plugin.remote.invalidDeployment", Message: "The deployment plan names a file outside the verified package inventory.",
			}
		}
	}
	id := "plugin-" + rand.Text()
	defer func() {
		cleanup, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
		defer cancel()
		s.recordDeploymentCleanup(ctx, kernel.ReleaseRemoteRunDirectory(cleanup, id))
	}()
	staging, err := kernel.CreateRemoteRuntimeStaging(ctx, id)
	if err != nil {
		return "", err
	}
	staging = path.Join(staging, "package")
	if err := kernel.CreateRemotePluginDirectory(ctx, staging); err != nil {
		return "", err
	}
	created := map[string]bool{staging: true}
	for _, name := range required {
		source := filepath.Join(variant.Directory, filepath.FromSlash(name))
		destination := path.Join(staging, name)
		parent := path.Dir(destination)
		if !created[parent] {
			if err := kernel.CreateRemotePluginDirectory(ctx, parent); err != nil {
				return "", err
			}
			created[parent] = true
		}
		digest, err := hashDeploymentFile(ctx, source)
		if err != nil {
			return "", err
		}
		// Keep the owner execute bit from the zip on Windows as well.
		mode := uint32(0o400 | files[name].Mode.Perm()&0o100)
		if err := kernel.UploadRemotePluginFile(ctx, source, destination, digest, mode); err != nil {
			return "", err
		}
	}
	return kernel.CommitRemotePluginDeployment(ctx, key, id)
}

func hashDeploymentFile(ctx context.Context, source string) (string, error) {
	if err := ctx.Err(); err != nil {
		return "", err
	}
	file, err := os.Open(source)
	if err != nil {
		return "", err
	}
	hash := sha256.New()
	_, copyErr := io.Copy(hash, deploymentReader{ctx, file})
	return hex.EncodeToString(hash.Sum(nil)), errors.Join(copyErr, file.Close())
}

type deploymentReader struct {
	context.Context
	io.Reader
}

func (r deploymentReader) Read(buffer []byte) (int, error) {
	if err := r.Err(); err != nil {
		return 0, err
	}
	return r.Reader.Read(buffer)
}

func (s *Service) recordDeploymentCleanup(ctx context.Context, err error) {
	if err != nil && s.RuntimeIssue != nil {
		s.RuntimeIssue(ctx, err)
	}
}
