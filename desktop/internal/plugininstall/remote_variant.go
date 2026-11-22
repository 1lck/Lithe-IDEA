package plugininstall

import (
	"context"
	"encoding/json"
	"errors"
	"os"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginpkg"
)

// RemoteVariant owns a private snapshot of a reviewed plugin package.
type RemoteVariant struct {
	Directory string
	Manifest  json.RawMessage
	Files     []pluginpkg.File
}

// ExtractRemoteVariant binds the manifest check to the same archive handle
// used to verify the marketplace digest. The caller owns the resulting directory.
func ExtractRemoteVariant(ctx context.Context, archivePath, sha256, stagingRoot string, review core.MarketplaceVariantReview, verify func(context.Context, core.MarketplaceVariantReview) (json.RawMessage, error)) (_ RemoteVariant, err error) {
	if sha256 == "" {
		return RemoteVariant{}, ErrArchiveDigest
	}
	staging, err := os.MkdirTemp(stagingRoot, "lithe-remote-variant-")
	if err != nil {
		return RemoteVariant{}, err
	}
	defer func() {
		if err != nil {
			err = errors.Join(err, os.RemoveAll(staging))
		}
	}()
	extracted, err := extractVerified(ctx, archivePath, sha256, staging)
	if err != nil {
		return RemoteVariant{}, err
	}
	if err := checkContentRoot(extracted.ContentRoot, review.PluginID); err != nil {
		return RemoteVariant{}, err
	}
	review.VariantManifest, err = readManifest(staging)
	if err != nil {
		return RemoteVariant{}, err
	}
	manifest, err := verify(ctx, review)
	if err != nil {
		return RemoteVariant{}, err
	}
	return RemoteVariant{Directory: staging, Manifest: manifest, Files: extracted.Files}, nil
}
