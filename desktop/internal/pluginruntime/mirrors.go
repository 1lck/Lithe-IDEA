package pluginruntime

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"sort"
	"sync"
	"sync/atomic"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/marketplace"
)

var (
	// Configurable timings so unit tests remain deterministic and bounded.
	mirrorProbeTimeout   = 3 * time.Second
	mirrorProbeGrace     = 250 * time.Millisecond
	mirrorSpeedGrace     = 8 * time.Second
	mirrorSpeedWindow    = 6 * time.Second
	mirrorMinBytesPerSec = int64(64 << 10) // 64 KiB/s

	errMirrorTooSlow = errors.New("managed runtime mirror transfer is too slow")
)

func candidateURLs(artifact Artifact) []string {
	urls := make([]string, 0, 1+len(artifact.Mirrors))
	seen := make(map[string]struct{}, 1+len(artifact.Mirrors))
	add := func(raw string) {
		if raw == "" {
			return
		}
		if _, ok := seen[raw]; ok {
			return
		}
		seen[raw] = struct{}{}
		urls = append(urls, raw)
	}
	add(artifact.URL)
	for _, mirror := range artifact.Mirrors {
		add(mirror)
	}
	return urls
}

func (m *Manager) downloadArchive(ctx context.Context, artifact Artifact, progress func(Progress)) (*marketplace.DownloadedArchive, func() error, error) {
	urls := candidateURLs(artifact)
	if len(urls) == 0 {
		return nil, nil, ErrArtifact
	}
	if len(urls) > 1 {
		urls = rankMirrors(ctx, m.Downloader.HTTPClient(), urls)
	}
	var lastErr error
	for index, location := range urls {
		if err := ctx.Err(); err != nil {
			return nil, nil, err
		}
		hasFallback := index < len(urls)-1
		download, cleanup, err := m.downloadFromMirror(ctx, artifact, location, hasFallback, progress)
		if err == nil {
			return download, cleanup, nil
		}
		lastErr = err
		if ctx.Err() != nil {
			return nil, nil, ctx.Err()
		}
	}
	return nil, nil, fmt.Errorf("%w: %w", ErrDownload, lastErr)
}

func (m *Manager) downloadFromMirror(ctx context.Context, artifact Artifact, location string, allowSpeedFailover bool, progress func(Progress)) (*marketplace.DownloadedArchive, func() error, error) {
	attemptCtx, cancelAttempt := context.WithCancelCause(ctx)
	defer cancelAttempt(nil)

	var received atomic.Int64
	var stopWatch func()
	if allowSpeedFailover && mirrorMinBytesPerSec > 0 && mirrorSpeedWindow > 0 {
		stopWatch = startSpeedMonitor(attemptCtx, &received, func() {
			cancelAttempt(errMirrorTooSlow)
		})
		defer stopWatch()
	}

	session := marketplace.NewArchiveSession(m.Downloader)
	download, err := session.Download(attemptCtx, core.MarketplaceAvailability{
		Status:      "available",
		DownloadURL: location,
		SHA256:      artifact.SHA256,
	}, func(p marketplace.ArchiveProgress) {
		received.Store(p.Received)
		if progress != nil {
			progress(Progress{ID: artifact.ID, Phase: "downloading", Received: p.Received, Total: p.Total})
		}
	})
	if err != nil {
		closeErr := session.Close()
		if cause := context.Cause(attemptCtx); errors.Is(cause, errMirrorTooSlow) && ctx.Err() == nil {
			return nil, nil, errors.Join(errMirrorTooSlow, closeErr)
		}
		return nil, nil, errors.Join(err, closeErr)
	}
	cleanup := func() error {
		return errors.Join(download.Discard(), session.Close())
	}
	return download, cleanup, nil
}

func startSpeedMonitor(ctx context.Context, received *atomic.Int64, onTooSlow func()) func() {
	done := make(chan struct{})
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		grace := time.NewTimer(mirrorSpeedGrace)
		defer grace.Stop()
		select {
		case <-ctx.Done():
			return
		case <-done:
			return
		case <-grace.C:
		}
		lastBytes := received.Load()
		minDelta := int64(float64(mirrorMinBytesPerSec) * mirrorSpeedWindow.Seconds())
		if minDelta < 1 {
			minDelta = 1
		}
		ticker := time.NewTicker(mirrorSpeedWindow)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-done:
				return
			case <-ticker.C:
				current := received.Load()
				if current-lastBytes < minDelta {
					onTooSlow()
					return
				}
				lastBytes = current
			}
		}
	}()
	var once sync.Once
	return func() {
		once.Do(func() { close(done) })
		wg.Wait()
	}
}

type mirrorProbeResult struct {
	index   int
	url     string
	ok      bool
	latency time.Duration
}

// rankMirrors probes candidate URLs with bounded parallel HEAD requests and
// returns reachable mirrors sorted by fastest response first, followed by any
// unprobed/failed candidates in their original declaration order as fallbacks.
func rankMirrors(ctx context.Context, client *http.Client, urls []string) []string {
	if len(urls) <= 1 || client == nil {
		return urls
	}
	probeCtx, cancel := context.WithTimeout(ctx, mirrorProbeTimeout)
	defer cancel()

	resultsCh := make(chan mirrorProbeResult, len(urls))
	var wg sync.WaitGroup
	for index, location := range urls {
		wg.Add(1)
		go func(idx int, target string) {
			defer wg.Done()
			start := time.Now()
			ok := probeMirrorHead(probeCtx, client, target)
			resultsCh <- mirrorProbeResult{
				index:   idx,
				url:     target,
				ok:      ok,
				latency: time.Since(start),
			}
		}(index, location)
	}
	go func() {
		wg.Wait()
		close(resultsCh)
	}()

	results := make([]mirrorProbeResult, 0, len(urls))
	var graceTimer *time.Timer
	var graceCh <-chan time.Time
	defer func() {
		if graceTimer != nil {
			graceTimer.Stop()
		}
	}()

collect:
	for len(results) < len(urls) {
		select {
		case res, open := <-resultsCh:
			if !open {
				break collect
			}
			results = append(results, res)
			if res.ok && graceTimer == nil && mirrorProbeGrace > 0 {
				graceTimer = time.NewTimer(mirrorProbeGrace)
				graceCh = graceTimer.C
			}
		case <-graceCh:
			cancel()
			break collect
		case <-probeCtx.Done():
			break collect
		}
	}
	cancel()
	// Drain any remaining goroutines so no background probe outlives rankMirrors.
	for range resultsCh {
	}

	var reachable []mirrorProbeResult
	seen := make(map[string]struct{}, len(urls))
	for _, res := range results {
		if res.ok {
			reachable = append(reachable, res)
			seen[res.url] = struct{}{}
		}
	}
	sort.Slice(reachable, func(i, j int) bool {
		if reachable[i].latency != reachable[j].latency {
			return reachable[i].latency < reachable[j].latency
		}
		return reachable[i].index < reachable[j].index
	})

	ranked := make([]string, 0, len(urls))
	for _, res := range reachable {
		ranked = append(ranked, res.url)
	}
	for _, location := range urls {
		if _, ok := seen[location]; !ok {
			ranked = append(ranked, location)
		}
	}
	return ranked
}

func probeMirrorHead(ctx context.Context, client *http.Client, target string) bool {
	request, err := http.NewRequestWithContext(ctx, http.MethodHead, target, nil)
	if err != nil {
		return false
	}
	response, err := client.Do(request)
	if err != nil {
		return false
	}
	_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 4096))
	_ = response.Body.Close()
	return response.StatusCode >= 200 && response.StatusCode < 300
}
