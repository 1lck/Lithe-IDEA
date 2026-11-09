package plugininstall

import (
	"archive/zip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginhost"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginpkg"
	"github.com/1lck/Lithe-IDEA/desktop/internal/plugintrust"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

// digestOf returns the SHA-256 of a file, the way a marketplace index carries it.
func digestOf(t *testing.T, path string) string {
	t.Helper()
	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(body)
	return hex.EncodeToString(sum[:])
}

// fakeValidator records the capabilities it was given and returns the manifest
// unchanged unless a test overrides it.
type fakeValidator struct {
	normalise    func(json.RawMessage) json.RawMessage
	err          error
	capabilities map[string][]int
}

func (v *fakeValidator) ValidatePluginManifest(_ context.Context, manifest json.RawMessage, capabilities map[string][]int) (json.RawMessage, error) {
	v.capabilities = capabilities
	if v.err != nil {
		return nil, v.err
	}
	if v.normalise != nil {
		return v.normalise(manifest), nil
	}
	return manifest, nil
}

// fakeReviewer reports the programs no earlier approval covered.
type fakeReviewer struct {
	permissions  []string
	programs     []json.RawMessage
	err          error
	seenApproved []json.RawMessage
}

func (r *fakeReviewer) ReviewPluginInstall(_ context.Context, _ json.RawMessage, _, _ string, approved []json.RawMessage) (plugintrust.Review, error) {
	r.seenApproved = approved
	if r.err != nil {
		return plugintrust.Review{}, r.err
	}
	return plugintrust.Review{
		Permissions: r.permissions,
		Programs:    r.programs,
		NewPrograms: programsNotIn(r.programs, approved),
	}, nil
}

func programsNotIn(programs, approved []json.RawMessage) []json.RawMessage {
	if len(approved) == 0 {
		return programs
	}
	var missing []json.RawMessage
	for _, program := range programs {
		seen := false
		for _, earlier := range approved {
			// Compare canonically: the approval file is written with indentation,
			// so a stored declaration is not byte-identical to the one Core just
			// returned.
			if canonicalProgram(earlier) == canonicalProgram(program) {
				seen = true
				break
			}
		}
		if !seen {
			missing = append(missing, program)
		}
	}
	return missing
}

func canonicalProgram(raw json.RawMessage) string {
	var value any
	if err := json.Unmarshal(raw, &value); err != nil {
		return string(raw)
	}
	encoded, err := json.Marshal(value)
	if err != nil {
		return string(raw)
	}
	return string(encoded)
}

// writeArchive writes a plugin archive holding a manifest and extra files.
func writeArchive(t *testing.T, manifest string, files map[string]string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "package.zip")
	file, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	writer := zip.NewWriter(file)
	write := func(name, body string) {
		header := &zip.FileHeader{Name: name, Method: zip.Deflate}
		header.SetMode(0o644)
		part, err := writer.CreateHeader(header)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := part.Write([]byte(body)); err != nil {
			t.Fatal(err)
		}
	}
	write(pluginpkg.ManifestFile, manifest)
	for name, body := range files {
		write(name, body)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}
	return path
}

const sampleManifest = `{"id":"io.github.lithe-idea.java-support","version":"1.0.0"}`

// newService builds a service with an isolated plugin root and approval file.
func newService(t *testing.T, validator pluginhost.ManifestValidator, reviewer Reviewer) (*Service, *plugintrust.Store, string) {
	t.Helper()
	approvals := plugintrust.New(store.At(t.TempDir()))
	return New(validator, reviewer, approvals, pluginhost.Declared()), approvals, t.TempDir()
}

// sampleReviewer reports one program and one permission.
func sampleReviewer() *fakeReviewer {
	return &fakeReviewer{
		permissions: []string{"workspace.read"},
		programs:    []json.RawMessage{json.RawMessage(`{"kind":"runtime","command":"java"}`)},
	}
}

func TestPrepareAsksForApprovalOnFirstInstall(t *testing.T) {
	service, _, root := newService(t, &fakeValidator{}, sampleReviewer())
	archive := writeArchive(t, sampleManifest, map[string]string{"lib/a.txt": "code"})
	plan, err := service.Prepare(context.Background(), Request{
		ArchivePath:   archive,
		Root:          root,
		Source:        plugintrust.Marketplace,
		ArchiveSHA256: digestOf(t, archive),
	})
	if err != nil {
		t.Fatalf("prepare: %v", err)
	}
	if !plan.NeedsApproval() {
		t.Fatalf("plan = %+v", plan)
	}
	if plan.ID != "io.github.lithe-idea.java-support" || plan.Version != "1.0.0" {
		t.Fatalf("identity = %q %q", plan.ID, plan.Version)
	}
	if plan.ContentDigest == "" {
		t.Fatal("the plan carries no content digest")
	}
	if len(plan.Review.Programs) != 1 || len(plan.Review.Permissions) != 1 {
		t.Fatalf("review = %+v", plan.Review)
	}
	if err := service.Discard(plan); err != nil {
		t.Fatalf("discard: %v", err)
	}
}

func TestPrepareUsesTheNormalisedManifest(t *testing.T) {
	validator := &fakeValidator{normalise: func(json.RawMessage) json.RawMessage {
		return json.RawMessage(`{"id":"normalised","version":"9.9.9"}`)
	}}
	service, _, root := newService(t, validator, sampleReviewer())
	plan, err := service.Prepare(context.Background(), Request{
		ArchivePath: writeArchive(t, sampleManifest, nil),
		Root:        root,
		Source:      plugintrust.Marketplace,
	})
	if err != nil {
		t.Fatalf("prepare: %v", err)
	}
	if plan.ID != "normalised" || plan.Version != "9.9.9" {
		t.Fatalf("identity = %q %q", plan.ID, plan.Version)
	}
	service.Discard(plan)
}

func TestPreparePassesCapabilitiesToTheValidator(t *testing.T) {
	validator := &fakeValidator{}
	capabilities := pluginhost.Declared().With("backend", 1)
	approvals := plugintrust.New(store.At(t.TempDir()))
	service := New(validator, sampleReviewer(), approvals, capabilities)
	plan, err := service.Prepare(context.Background(), Request{
		ArchivePath: writeArchive(t, sampleManifest, nil),
		Root:        t.TempDir(),
		Source:      plugintrust.Marketplace,
	})
	if err != nil {
		t.Fatalf("prepare: %v", err)
	}
	if versions := validator.capabilities["backend"]; len(versions) != 1 || versions[0] != 1 {
		t.Fatalf("capabilities = %v", validator.capabilities)
	}
	service.Discard(plan)
}

func TestPrepareReusesAnEarlierApproval(t *testing.T) {
	reviewer := sampleReviewer()
	service, _, root := newService(t, &fakeValidator{}, reviewer)
	request := Request{
		ArchivePath: writeArchive(t, sampleManifest, map[string]string{"lib/a.txt": "code"}),
		Root:        root,
		Source:      plugintrust.Marketplace,
	}
	request.ArchiveSHA256 = digestOf(t, request.ArchivePath)
	first, err := service.Prepare(context.Background(), request)
	if err != nil {
		t.Fatalf("first prepare: %v", err)
	}
	if !first.NeedsApproval() {
		t.Fatal("the first installation did not ask for approval")
	}
	if _, err := service.Commit(first); err != nil {
		t.Fatalf("commit: %v", err)
	}
	second, err := service.Prepare(context.Background(), request)
	if err != nil {
		t.Fatalf("second prepare: %v", err)
	}
	defer service.Discard(second)
	if second.NeedsApproval() {
		t.Fatalf("the second installation asked again: %+v", second.Decision)
	}
	if len(reviewer.seenApproved) != 1 {
		t.Fatalf("the earlier programs were not offered to Core: %v", reviewer.seenApproved)
	}
}

func TestPrepareAsksAgainForADiskPackage(t *testing.T) {
	service, _, root := newService(t, &fakeValidator{}, sampleReviewer())
	request := Request{
		ArchivePath: writeArchive(t, sampleManifest, map[string]string{"lib/a.txt": "code"}),
		Root:        root,
		Source:      plugintrust.Marketplace,
	}
	request.ArchiveSHA256 = digestOf(t, request.ArchivePath)
	first, err := service.Prepare(context.Background(), request)
	if err != nil {
		t.Fatalf("first prepare: %v", err)
	}
	if _, err := service.Commit(first); err != nil {
		t.Fatalf("commit: %v", err)
	}
	disk := request
	disk.Source = plugintrust.Disk
	plan, err := service.Prepare(context.Background(), disk)
	if err != nil {
		t.Fatalf("prepare from disk: %v", err)
	}
	defer service.Discard(plan)
	if !plan.NeedsApproval() {
		t.Fatal("a package chosen on disk reused a marketplace approval")
	}
}

func TestPrepareCleansStagingOnEveryFailure(t *testing.T) {
	cases := map[string]struct {
		validator pluginhost.ManifestValidator
		reviewer  Reviewer
		archive   func(t *testing.T) string
	}{
		"validator refuses": {
			validator: &fakeValidator{err: errors.New("core refused")},
			reviewer:  sampleReviewer(),
			archive: func(t *testing.T) string {
				return writeArchive(t, sampleManifest, nil)
			},
		},
		"reviewer fails": {
			validator: &fakeValidator{},
			reviewer:  &fakeReviewer{err: errors.New("review failed")},
			archive: func(t *testing.T) string {
				return writeArchive(t, sampleManifest, nil)
			},
		},
		"manifest without identity": {
			validator: &fakeValidator{},
			reviewer:  sampleReviewer(),
			archive: func(t *testing.T) string {
				return writeArchive(t, `{"id":""}`, nil)
			},
		},
		"manifest is not JSON": {
			validator: &fakeValidator{},
			reviewer:  sampleReviewer(),
			archive: func(t *testing.T) string {
				return writeArchive(t, "not json", nil)
			},
		},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			service, _, root := newService(t, tc.validator, tc.reviewer)
			if _, err := service.Prepare(context.Background(), Request{
				ArchivePath: tc.archive(t),
				Root:        root,
				Source:      plugintrust.Marketplace,
			}); err == nil {
				t.Fatal("a broken preparation succeeded")
			}
			staging := filepath.Join(root, ".staging")
			entries, err := os.ReadDir(staging)
			if err != nil && !errors.Is(err, os.ErrNotExist) {
				t.Fatalf("read staging: %v", err)
			}
			if len(entries) != 0 {
				t.Fatalf("a failed preparation left %d staging entries", len(entries))
			}
		})
	}
}

func TestPrepareRefusesUnusableRequests(t *testing.T) {
	service, _, root := newService(t, &fakeValidator{}, sampleReviewer())
	cases := map[string]Request{
		"relative archive": {ArchivePath: "package.zip", Root: root, Source: plugintrust.Marketplace},
		"relative root":    {ArchivePath: filepath.Join(t.TempDir(), "a.zip"), Root: "root", Source: plugintrust.Marketplace},
		"unknown source":   {ArchivePath: filepath.Join(t.TempDir(), "a.zip"), Root: root, Source: "network"},
	}
	for name, request := range cases {
		t.Run(name, func(t *testing.T) {
			if _, err := service.Prepare(context.Background(), request); !errors.Is(err, ErrRequest) {
				t.Fatalf("err = %v", err)
			}
		})
	}
}

func TestPrepareRefusesAnArchiveWithoutManifest(t *testing.T) {
	service, _, root := newService(t, &fakeValidator{}, sampleReviewer())
	path := filepath.Join(t.TempDir(), "package.zip")
	file, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	writer := zip.NewWriter(file)
	part, err := writer.Create("lib/a.txt")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := part.Write([]byte("code")); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err := service.Prepare(context.Background(), Request{
		ArchivePath: path,
		Root:        root,
		Source:      plugintrust.Marketplace,
	}); !errors.Is(err, pluginpkg.ErrManifestMissing) {
		t.Fatalf("err = %v", err)
	}
}

func TestCommitInstallsAndRecordsTheApproval(t *testing.T) {
	service, approvals, root := newService(t, &fakeValidator{}, sampleReviewer())
	archive := writeArchive(t, sampleManifest, map[string]string{"lib/a.txt": "code"})
	digest := digestOf(t, archive)
	plan, err := service.Prepare(context.Background(), Request{
		ArchivePath:   archive,
		Root:          root,
		Source:        plugintrust.Marketplace,
		ArchiveSHA256: digest,
	})
	if err != nil {
		t.Fatalf("prepare: %v", err)
	}
	installed, err := service.Commit(plan)
	if err != nil {
		t.Fatalf("commit: %v", err)
	}
	if _, err := os.Stat(filepath.Join(installed.Path, pluginpkg.ManifestFile)); err != nil {
		t.Fatalf("the manifest is not installed: %v", err)
	}
	if _, err := os.Stat(plan.Staging); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("staging survived the commit: %v", err)
	}
	record, found, err := approvals.Record(installed.ID, installed.Version)
	if err != nil || !found {
		t.Fatalf("record: %v, found = %v", err, found)
	}
	if record.ContentDigest != plan.ContentDigest || record.ArchiveSHA256 != digest {
		t.Fatalf("record = %+v", record)
	}
}

func TestPrepareRefusesAReplacedArchive(t *testing.T) {
	service, _, root := newService(t, &fakeValidator{}, sampleReviewer())
	archive := writeArchive(t, sampleManifest, map[string]string{"lib/a.txt": "code"})
	digest := digestOf(t, archive)
	// The bytes on disk changed after the download layer checked them.
	replacement := writeArchive(t, sampleManifest, map[string]string{"lib/a.txt": "other"})
	if err := os.Rename(replacement, archive); err != nil {
		t.Fatal(err)
	}
	_, err := service.Prepare(context.Background(), Request{
		ArchivePath:   archive,
		Root:          root,
		Source:        plugintrust.Marketplace,
		ArchiveSHA256: digest,
	})
	if !errors.Is(err, ErrArchiveDigest) {
		t.Fatalf("err = %v", err)
	}
	entries, readErr := os.ReadDir(filepath.Join(root, ".staging"))
	if readErr != nil && !errors.Is(readErr, os.ErrNotExist) {
		t.Fatalf("read staging: %v", readErr)
	}
	if len(entries) != 0 {
		t.Fatalf("a refused archive left %d staging entries", len(entries))
	}
}

func TestPrepareRefusesAMalformedDigest(t *testing.T) {
	service, _, root := newService(t, &fakeValidator{}, sampleReviewer())
	archive := writeArchive(t, sampleManifest, nil)
	if _, err := service.Prepare(context.Background(), Request{
		ArchivePath:   archive,
		Root:          root,
		Source:        plugintrust.Marketplace,
		ArchiveSHA256: "not-a-digest",
	}); !errors.Is(err, ErrArchiveDigest) {
		t.Fatalf("err = %v", err)
	}
}

func TestCommitRefusesAnUnpreparedPlan(t *testing.T) {
	service, _, _ := newService(t, &fakeValidator{}, sampleReviewer())
	if _, err := service.Commit(Plan{}); !errors.Is(err, ErrNotPrepared) {
		t.Fatalf("err = %v", err)
	}
}

func TestCommitRefusesAnExistingVersion(t *testing.T) {
	service, _, root := newService(t, &fakeValidator{}, sampleReviewer())
	request := Request{
		ArchivePath: writeArchive(t, sampleManifest, nil),
		Root:        root,
		Source:      plugintrust.Marketplace,
	}
	first, err := service.Prepare(context.Background(), request)
	if err != nil {
		t.Fatalf("prepare: %v", err)
	}
	if _, err := service.Commit(first); err != nil {
		t.Fatalf("commit: %v", err)
	}
	second, err := service.Prepare(context.Background(), request)
	if err != nil {
		t.Fatalf("prepare: %v", err)
	}
	defer service.Discard(second)
	if _, err := service.Commit(second); !errors.Is(err, pluginpkg.ErrPackageExists) {
		t.Fatalf("err = %v", err)
	}
}

func TestDiscardRemovesStaging(t *testing.T) {
	service, _, root := newService(t, &fakeValidator{}, sampleReviewer())
	plan, err := service.Prepare(context.Background(), Request{
		ArchivePath: writeArchive(t, sampleManifest, nil),
		Root:        root,
		Source:      plugintrust.Marketplace,
	})
	if err != nil {
		t.Fatalf("prepare: %v", err)
	}
	if err := service.Discard(plan); err != nil {
		t.Fatalf("discard: %v", err)
	}
	if _, err := os.Stat(plan.Staging); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("staging survived the discard: %v", err)
	}
	if err := service.Discard(Plan{}); err != nil {
		t.Fatalf("discarding nothing failed: %v", err)
	}
}

func TestContentDigestIsStableAndSensitive(t *testing.T) {
	service, _, root := newService(t, &fakeValidator{}, sampleReviewer())
	request := Request{
		ArchivePath: writeArchive(t, sampleManifest, map[string]string{"lib/a.txt": "code"}),
		Root:        root,
		Source:      plugintrust.Marketplace,
	}
	first, err := service.Prepare(context.Background(), request)
	if err != nil {
		t.Fatalf("prepare: %v", err)
	}
	firstDigest := first.ContentDigest
	service.Discard(first)
	second, err := service.Prepare(context.Background(), request)
	if err != nil {
		t.Fatalf("prepare: %v", err)
	}
	if second.ContentDigest != firstDigest {
		t.Fatalf("the same package digested twice: %q then %q", firstDigest, second.ContentDigest)
	}
	service.Discard(second)

	changed, err := service.Prepare(context.Background(), Request{
		ArchivePath: writeArchive(t, sampleManifest, map[string]string{"lib/a.txt": "different"}),
		Root:        root,
		Source:      plugintrust.Marketplace,
	})
	if err != nil {
		t.Fatalf("prepare: %v", err)
	}
	defer service.Discard(changed)
	if changed.ContentDigest == firstDigest {
		t.Fatal("a changed package kept the same content digest")
	}
}
