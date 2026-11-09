// Package plugininstall runs one plugin installation from a downloaded archive
// to an installed package.
//
// It is the seam between the layers below it: pluginpkg extracts and installs,
// pluginhost validates the manifest against the capabilities this client
// implements, and plugintrust decides whether an earlier approval still covers
// the package. Nothing here talks to Core directly; the caller supplies a
// validator and a reviewer, so the whole flow is testable without the kernel.
//
// An installation has two phases because a user has to see what a package asks
// for before it is installed. Prepare extracts the archive, validates the
// manifest, digests the tree and obtains Core's review without writing anything
// the user can run. Commit is called only after the user has seen the review, and
// either reuses an earlier approval or one the caller just obtained.
package plugininstall

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"

	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginhost"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginpkg"
	"github.com/1lck/Lithe-IDEA/desktop/internal/plugintrust"
)

const (
	// MaxManifestBytes bounds the manifest read from an extracted package. It is
	// a host budget: the contract limits the fields a manifest may carry but
	// names no size for the file itself.
	MaxManifestBytes = 8 << 20
)

var (
	// ErrRequest reports an installation request this host will not run.
	ErrRequest = errors.New("plugin installation request is not usable")
	// ErrManifest reports a manifest that is missing, too large or not valid JSON.
	ErrManifest = errors.New("plugin package manifest is not readable")
	// ErrNotPrepared reports a commit or discard without a prepared package.
	ErrNotPrepared = errors.New("plugin package was not prepared")
	// ErrArchiveDigest reports an archive that no longer matches the digest the
	// download layer verified.
	ErrArchiveDigest = errors.New("plugin archive does not match the verified digest")
)

// Reviewer is Core's install review. Review is a local shape rather than
// core.MarketplaceReview so that this package stays free of the cgo bridge; the
// caller that owns the Core client converts between them.
type Reviewer interface {
	ReviewPluginInstall(ctx context.Context, manifest json.RawMessage, expectedID, expectedVersion string, approvedPrograms []json.RawMessage) (plugintrust.Review, error)
}

// Request is one archive the host is about to install.
type Request struct {
	// ArchivePath is the downloaded archive.
	ArchivePath string
	// Root is the plugin root, normally pluginpkg.DefaultRoot.
	Root string
	// Source says where the archive came from, which decides whether an earlier
	// approval may be reused.
	Source plugintrust.Source
	// ArchiveSHA256 is the digest the download layer verified against the index.
	ArchiveSHA256 string
	// ExpectedID and ExpectedVersion pin the marketplace entry this archive is
	// supposed to be. They are empty for a package the user picked themselves.
	ExpectedID      string
	ExpectedVersion string
}

// Plan is a package that was extracted and reviewed but not installed.
type Plan struct {
	// Staging is the extracted package tree. Commit consumes it.
	Staging string
	// ID and Version come from Core's normalised manifest.
	ID      string
	Version string
	// Manifest is Core's normalised manifest, not the bytes read from disk.
	Manifest json.RawMessage
	// ContentDigest is the digest of the extracted tree.
	ContentDigest string
	// Review is Core's install review, ready to show to the user.
	Review plugintrust.Review
	// Decision says whether an earlier approval covers this package.
	Decision plugintrust.Decision
	// Source, ArchiveSHA256 and Root repeat the request for Commit.
	Source        plugintrust.Source
	ArchiveSHA256 string
	Root          string
}

// NeedsApproval reports that the user has to confirm the review before Commit.
func (p Plan) NeedsApproval() bool { return !p.Decision.Reuse }

// ApprovalError reports that a package was installed but its approval record
// could not be written. The installation itself succeeded.
type ApprovalError struct {
	// Installed is the package that is now on disk.
	Installed pluginpkg.Installed
	// Err is why the record could not be written.
	Err error
}

func (e *ApprovalError) Error() string {
	return fmt.Sprintf("plugin %s %s is installed but its approval was not recorded: %v", e.Installed.ID, e.Installed.Version, e.Err)
}

func (e *ApprovalError) Unwrap() error { return e.Err }

// Service prepares and commits plugin installations.
type Service struct {
	validator    pluginhost.ManifestValidator
	reviewer     Reviewer
	approvals    *plugintrust.Store
	capabilities pluginhost.Capabilities
}

// New returns a service that validates manifests against capabilities and keeps
// approvals in approvals.
func New(validator pluginhost.ManifestValidator, reviewer Reviewer, approvals *plugintrust.Store, capabilities pluginhost.Capabilities) *Service {
	return &Service{validator: validator, reviewer: reviewer, approvals: approvals, capabilities: capabilities}
}

// Prepare extracts and reviews a package without installing it. A failure leaves
// no staging directory behind.
func (s *Service) Prepare(ctx context.Context, request Request) (plan Plan, err error) {
	if err := checkRequest(request); err != nil {
		return Plan{}, err
	}
	if s.validator == nil || s.reviewer == nil || s.approvals == nil {
		return Plan{}, errors.New("plugininstall: the service is missing a collaborator")
	}
	staging, err := pluginpkg.NewStaging(request.Root)
	if err != nil {
		return Plan{}, err
	}
	defer func() {
		if err != nil {
			plan = Plan{}
			err = errors.Join(err, os.RemoveAll(staging))
		}
	}()
	extracted, err := extractVerified(ctx, request, staging)
	if err != nil {
		return Plan{}, err
	}
	manifest, err := readManifest(staging)
	if err != nil {
		return Plan{}, err
	}
	normalised, err := pluginhost.Validate(ctx, s.validator, manifest, s.capabilities)
	if err != nil {
		return Plan{}, err
	}
	identity, err := decodeIdentity(normalised)
	if err != nil {
		return Plan{}, err
	}
	digest, err := ContentDigest(staging, extracted.Files)
	if err != nil {
		return Plan{}, err
	}
	record, found, err := s.approvals.Record(identity.ID, identity.Version)
	if err != nil {
		return Plan{}, err
	}
	// The earlier program set goes to Core so that the review reports only the
	// programs the user has not approved yet.
	review, err := s.reviewer.ReviewPluginInstall(ctx, normalised, request.ExpectedID, request.ExpectedVersion, record.ApprovedPrograms)
	if err != nil {
		return Plan{}, err
	}
	decision := plugintrust.Decide(record, found, plugintrust.Request{
		Source:        request.Source,
		ArchiveSHA256: request.ArchiveSHA256,
		ContentDigest: digest,
		Review:        review,
	})
	return Plan{
		Staging:       staging,
		ID:            identity.ID,
		Version:       identity.Version,
		Manifest:      normalised,
		ContentDigest: digest,
		Review:        review,
		Decision:      decision,
		Source:        request.Source,
		ArchiveSHA256: request.ArchiveSHA256,
		Root:          request.Root,
	}, nil
}

// Commit installs a prepared package and records the approval.
//
// When it returns an *ApprovalError the package is installed and only the record
// failed, which means the next installation of the same version asks the user
// again. Every other error leaves the package uninstalled.
func (s *Service) Commit(plan Plan) (pluginpkg.Installed, error) {
	if plan.Staging == "" || plan.ID == "" || plan.Version == "" || plan.Root == "" {
		return pluginpkg.Installed{}, ErrNotPrepared
	}
	installed, err := pluginpkg.Install(plan.Root, plan.ID, plan.Version, plan.Staging)
	if err != nil {
		return pluginpkg.Installed{}, err
	}
	record := plugintrust.RecordFor(plan.ID, plan.Version, plugintrust.Request{
		Source:        plan.Source,
		ArchiveSHA256: plan.ArchiveSHA256,
		ContentDigest: plan.ContentDigest,
		Review:        plan.Review,
	})
	if err := s.approvals.Approve(record); err != nil {
		return installed, &ApprovalError{Installed: installed, Err: err}
	}
	return installed, nil
}

// Discard removes a prepared package that will not be installed.
func (s *Service) Discard(plan Plan) error {
	if plan.Staging == "" {
		return nil
	}
	return os.RemoveAll(plan.Staging)
}

// ContentDigest hashes an extracted tree: for every file, in path order, the
// path, a NUL, the file's bytes, and a NUL.
//
// It is the provenance value the contract records alongside the archive digest.
// The path order comes from Extract, so the same package always digests the same
// way.
func ContentDigest(directory string, files []pluginpkg.File) (string, error) {
	hash := sha256.New()
	for _, file := range files {
		hash.Write([]byte(file.Path))
		hash.Write([]byte{0})
		if err := hashPath(hash, filepath.Join(directory, filepath.FromSlash(file.Path))); err != nil {
			return "", err
		}
		hash.Write([]byte{0})
	}
	return hex.EncodeToString(hash.Sum(nil)), nil
}

// hashPath streams one file into writer.
func hashPath(writer io.Writer, path string) error {
	file, err := os.Open(path)
	if err != nil {
		return err
	}
	copyErr := hashFile(writer, file)
	closeErr := file.Close()
	return errors.Join(copyErr, closeErr)
}

func hashFile(writer io.Writer, source io.Reader) error {
	copied, copyErr := io.Copy(writer, source)
	if copyErr != nil {
		return copyErr
	}
	if copied < 0 {
		return errors.New("plugininstall: negative byte count")
	}
	return nil
}

// extractVerified opens the archive once, checks the digest over that handle and
// extracts from the same handle.
//
// The download layer checked the digest of the bytes it received. Hashing a path
// and then opening it again would leave a window in which the file is replaced,
// so the check and the extraction share one open file.
func extractVerified(ctx context.Context, request Request, staging string) (pluginpkg.Package, error) {
	if err := ctx.Err(); err != nil {
		return pluginpkg.Package{}, err
	}
	file, err := os.Open(request.ArchivePath)
	if err != nil {
		return pluginpkg.Package{}, err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return pluginpkg.Package{}, err
	}
	if !info.Mode().IsRegular() {
		// A named pipe or a directory would block or read something else.
		return pluginpkg.Package{}, fmt.Errorf("%w: %s is not a regular file", ErrArchiveDigest, request.ArchivePath)
	}
	if request.ArchiveSHA256 != "" {
		if err := verifyDigest(file, request.ArchivePath, request.ArchiveSHA256); err != nil {
			return pluginpkg.Package{}, err
		}
		if _, err := file.Seek(0, io.SeekStart); err != nil {
			return pluginpkg.Package{}, err
		}
	}
	return pluginpkg.ExtractFrom(ctx, file, info.Size(), staging)
}

// verifyDigest hashes the open archive and compares it with the digest the
// download layer checked against the index.
func verifyDigest(source io.Reader, path, want string) error {
	expected, err := hex.DecodeString(want)
	if err != nil || len(expected) != sha256.Size {
		return fmt.Errorf("%w: %q is not a SHA-256 digest", ErrArchiveDigest, want)
	}
	hash := sha256.New()
	if err := hashFile(hash, source); err != nil {
		return err
	}
	if subtle.ConstantTimeCompare(hash.Sum(nil), expected) != 1 {
		return fmt.Errorf("%w: %s", ErrArchiveDigest, path)
	}
	return nil
}

// readManifest reads the package manifest from staging, bounded and validated.
func readManifest(directory string) (json.RawMessage, error) {
	file, err := os.Open(filepath.Join(directory, pluginpkg.ManifestFile))
	if err != nil {
		return nil, fmt.Errorf("%w: %w", ErrManifest, err)
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, MaxManifestBytes+1))
	if err != nil {
		return nil, fmt.Errorf("%w: %w", ErrManifest, err)
	}
	if len(data) > MaxManifestBytes {
		return nil, fmt.Errorf("%w: larger than %d bytes", ErrManifest, MaxManifestBytes)
	}
	if !json.Valid(data) {
		return nil, fmt.Errorf("%w: not valid JSON", ErrManifest)
	}
	return json.RawMessage(data), nil
}

// identity is the two manifest fields this package keys everything by.
type identity struct {
	ID      string `json:"id"`
	Version string `json:"version"`
}

func decodeIdentity(manifest json.RawMessage) (identity, error) {
	var decoded identity
	if err := json.Unmarshal(manifest, &decoded); err != nil {
		return identity{}, fmt.Errorf("%w: %w", ErrManifest, err)
	}
	if decoded.ID == "" || decoded.Version == "" {
		return identity{}, fmt.Errorf("%w: no id or version", ErrManifest)
	}
	return decoded, nil
}

func checkRequest(request Request) error {
	if request.ArchivePath == "" || !filepath.IsAbs(request.ArchivePath) {
		return fmt.Errorf("%w: the archive path must be absolute", ErrRequest)
	}
	if request.Root == "" || !filepath.IsAbs(request.Root) {
		return fmt.Errorf("%w: the plugin root must be absolute", ErrRequest)
	}
	switch request.Source {
	case plugintrust.Marketplace, plugintrust.Disk:
	default:
		return fmt.Errorf("%w: unknown source %q", ErrRequest, request.Source)
	}
	return nil
}
