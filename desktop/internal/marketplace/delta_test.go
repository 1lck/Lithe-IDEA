package marketplace

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/installedpackagetest"
)

func deltaDigest(body []byte) string {
	hash := sha256.Sum256(body)
	return hex.EncodeToString(hash[:])
}

// The patch was produced by the publisher's zstd --patch-from command. The
// input is deliberately incompressible without the exact 16 KiB reference.
func deltaFixture(t *testing.T) (base, target, patch []byte) {
	t.Helper()
	for i := range 512 {
		hash := sha256.Sum256(binary.LittleEndian.AppendUint16(nil, uint16(i)))
		base = append(base, hash[:]...)
	}
	target = bytes.Clone(base)
	copy(target[2048:], "Lithe delta fixture target bytes!")
	patch, err := hex.DecodeString("28b52ffd64003f7d010014024c697468652064656c7461206669787475726520746172676574206279746573210200e1be80fffe07809f01016d14474a")
	if err != nil {
		t.Fatal(err)
	}
	return base, target, patch
}

func TestMarketplaceDeltaTransport(t *testing.T) {
	for _, scenario := range []string{"exact", "no base", "corrupt base", "corrupt patch", "wrong output", "no companion", "cancel", "cache unavailable"} {
		t.Run(scenario, func(t *testing.T) {
			verifyMarketplaceDelta(t, ArchiveCache{directory: t.TempDir()}, scenario)
		})
	}
}

func TestMarketplaceDeltaLeavesInstalledPackageUnchanged(t *testing.T) {
	if !installedpackagetest.Run(t) {
		return
	}
	cache, err := UserArchiveCache()
	if err != nil {
		t.Fatal(err)
	}
	installedpackagetest.Outside(t, cache.directory)
	verifyMarketplaceDelta(t, cache, "exact")
}

func verifyMarketplaceDelta(t *testing.T, cache ArchiveCache, scenario string) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	base, target, patch := deltaFixture(t)
	if scenario == "wrong output" {
		target[0] ^= 1
	}
	const repo = "https://github.com/example/delta"
	const zipURL = repo + "/releases/download/v2.0.0/delta.zip"
	const patchURL = repo + "/releases/download/v2.0.0/delta.from-1.0.0.zip.zst"
	const companion = "https://example.test/lithe-plugin-deltas.json"
	offer := core.MarketplacePlugin{
		ID: "io.example.delta", Repository: repo, MarketplaceDeltasURL: companion,
		Availability: core.MarketplaceAvailability{
			Status: "available", Version: "2.0.0", DownloadURL: zipURL, SHA256: deltaDigest(target),
		},
	}
	delta := core.MarketplaceDelta{
		PluginID: offer.ID, Platform: "darwin-arm64", FromVersion: "1.0.0", FromSHA256: deltaDigest(base),
		ToVersion: offer.Availability.Version, ToSHA256: offer.Availability.SHA256, ToSize: int64(len(target)),
		Format: "zstd-prefix", DownloadURL: patchURL, SHA256: deltaDigest(patch), Size: int64(len(patch)),
	}
	raw, err := json.Marshal(map[string]any{"schemaVersion": 0, "patches": []core.MarketplaceDelta{delta}})
	if err != nil {
		t.Fatal(err)
	}
	if scenario != "no base" {
		if err := os.MkdirAll(cache.directory, 0o700); err != nil {
			t.Fatal(err)
		}
		path, err := cache.path(delta.FromSHA256)
		if err != nil {
			t.Fatal(err)
		}
		if scenario == "corrupt base" {
			base[0] ^= 1
		}
		if err := os.WriteFile(path, base, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	if scenario == "cache unavailable" {
		if err := os.Mkdir(filepath.Join(cache.directory, archiveCacheLockFile), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	if scenario == "corrupt patch" {
		patch[0] ^= 1
	}
	var requests []string
	client := &http.Client{Transport: transportFunc(func(request *http.Request) (*http.Response, error) {
		location := request.URL.String()
		requests = append(requests, location)
		var body []byte
		status := http.StatusOK
		switch location {
		case companion:
			body = raw
			if scenario == "no companion" {
				status, body = http.StatusNotFound, nil
			}
		case patchURL:
			body = patch
			if scenario == "cancel" {
				cancel()
				return nil, ctx.Err()
			}
		case zipURL:
			body = target
		default:
			t.Errorf("unexpected request %s", request.URL)
			status = http.StatusNotFound
		}
		return &http.Response{
			StatusCode: status, Header: make(http.Header), Body: io.NopCloser(bytes.NewReader(body)),
			ContentLength: int64(len(body)), Request: request,
		}, nil
	})}
	var notices []error
	root := t.TempDir()
	kernel := core.NewClient()
	downloader := newArchiveDownloader(client, root)
	archive, err := New(kernel, client).DownloadUpdate(ctx, kernel, cache, downloader, offer, delta.Platform,
		DeltaBase{delta.FromVersion, delta.FromSHA256}, func() (*DownloadedArchive, error) {
			return downloader.Download(ctx, offer.Availability)
		}, nil, func(err error) { notices = append(notices, err) })
	if scenario == "cancel" {
		if err != context.Canceled || archive != nil || len(requests) != 2 {
			t.Fatalf("cancel = %v, archive = %v, requests = %v", err, archive, requests)
		}
		assertArchiveRootEmpty(t, root)
		return
	}
	if err != nil {
		t.Fatal(err)
	}
	if got, err := os.ReadFile(archive.Path()); err != nil || !bytes.Equal(got, target) {
		t.Fatalf("target ZIP did not match: %v", err)
	}
	switch scenario {
	case "exact":
		if len(notices) != 0 || strings.Join(requests, " ") != companion+" "+patchURL {
			t.Fatalf("exact patch requested %v, reports %v", requests, notices)
		}
	case "no base":
		if len(notices) != 0 || strings.Join(requests, " ") != zipURL {
			t.Fatalf("no-base update requested %v, reports %v", requests, notices)
		}
	case "no companion":
		if len(notices) != 0 || strings.Join(requests, " ") != companion+" "+zipURL {
			t.Fatalf("no-companion update requested %v, reports %v", requests, notices)
		}
	case "cache unavailable":
		if len(notices) != 1 || strings.Join(requests, " ") != companion+" "+patchURL {
			t.Fatalf("unavailable cache update requested %v, reports %v", requests, notices)
		}
	default:
		if len(notices) != 1 || strings.Join(requests, " ") != companion+" "+patchURL+" "+zipURL {
			t.Fatalf("fallback requested %v, reports %v", requests, notices)
		}
	}
	wantCached := scenario != "cache unavailable"
	if cached, err := cache.base(delta.ToSHA256); (cached != "") != wantCached || err != nil {
		t.Fatalf("target cache = %q, %v", cached, err)
	}
	if err := archive.Discard(); err != nil {
		t.Fatal(err)
	}
	assertArchiveRootEmpty(t, root)
}
