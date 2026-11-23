// Package marketplace fetches plugin indexes and delegates their interpretation to Core.
package marketplace

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

const (
	// OfficialIndexURL follows the current main repository, rather than the
	// retired organization URL that redirects to a temporary repository (#1781).
	OfficialIndexURL = "https://raw.githubusercontent.com/1lck/Lithe-IDEA/HEAD/Plugins/marketplace/index.json"
	// CommunityRepositoryURL is the community store, a GitHub repository whose index Core
	// resolves to the file the repository keeps at its root.
	CommunityRepositoryURL = "https://github.com/Lithe-IDEA/Lithe-store"
	// MaxIndexBytes matches the existing macOS market's index budget.
	MaxIndexBytes = 5 << 20
	fetchTimeout  = 20 * time.Second
	maxRedirects  = 10
	// commitLookupTimeout bounds the newest-commit lookup, so an unreachable GitHub API costs
	// a few seconds before the canonical index is read instead of the whole fetch budget.
	commitLookupTimeout = 5 * time.Second
)

var (
	ErrIndexTooLarge  = errors.New("marketplace index exceeds the size limit")
	ErrInvalidJSON    = errors.New("marketplace index is not valid JSON")
	ErrUnsafeRedirect = errors.New("marketplace redirect is not a safe HTTPS URL")
)

// Evaluator is the shared Core marketplace contract, supplied by core.Client.
type Evaluator interface {
	ResolveMarketplaceSource(context.Context, string) (core.MarketplaceSource, error)
	PinMarketplaceSource(ctx context.Context, url, commit string) (core.MarketplaceSource, error)
	ValidateMarketplaceIndex(context.Context, json.RawMessage, core.MarketplaceSourceKind, string, map[string][]int) (core.MarketplaceIndex, error)
}

// CommitLookup returns the newest commit of ref in repository as a full SHA.
type CommitLookup func(ctx context.Context, repository core.GitHubRepo, ref string) (string, error)

// Service holds a reusable HTTP client. It stores no index inside application resources.
type Service struct {
	core Evaluator
	http *http.Client
	// latest and fallback are set by PinToLatestCommit; with latest nil every file is read
	// from its canonical URL.
	latest   CommitLookup
	fallback func(context.Context, error)
}

// New creates a marketplace service. A nil client uses Go's default transport;
// a client can be supplied to apply product network policy or test offline.
func New(evaluator Evaluator, client *http.Client) *Service {
	return &Service{core: evaluator, http: marketplaceHTTPClient(client, fetchTimeout)}
}

// PinToLatestCommit makes s read a GitHub-hosted source at the newest commit latest reports
// rather than at its branch URL, which raw.githubusercontent.com serves from a cache for up to
// five minutes after a push. When the lookup or the pinned read fails, s reads the canonical URL
// and hands the failure to fallback with the fetch's context; fallback must be safe to call from
// any goroutine.
func (s *Service) PinToLatestCommit(latest CommitLookup, fallback func(context.Context, error)) *Service {
	s.latest, s.fallback = latest, fallback
	return s
}

// marketplaceHTTPClient preserves the supplied transport and redirect policy,
// while refusing redirects that would downgrade or embed credentials. A
// positive timeout bounds each request as a whole, keeping a shorter one the
// client sets; zero leaves the client's own.
func marketplaceHTTPClient(client *http.Client, timeout time.Duration) *http.Client {
	if client == nil {
		client = &http.Client{}
	}
	copy := *client
	if timeout > 0 && (copy.Timeout == 0 || copy.Timeout > timeout) {
		copy.Timeout = timeout
	}
	previous := copy.CheckRedirect
	copy.CheckRedirect = func(request *http.Request, via []*http.Request) error {
		if !strings.EqualFold(request.URL.Scheme, "https") || request.URL.Host == "" || request.URL.User != nil || len(via) >= maxRedirects {
			return ErrUnsafeRedirect
		}
		if previous != nil {
			return previous(request, via)
		}
		return nil
	}
	return &copy
}

// Snapshot pairs a validated catalog with the canonical source that produced it.
type Snapshot struct {
	Source core.MarketplaceSource
	Index  core.MarketplaceIndex
}

// RecommendationBundle holds a raw marketplace index and its companion workspace recommendations catalog.
type RecommendationBundle struct {
	Source          core.MarketplaceSource
	SourceKind      core.MarketplaceSourceKind
	Index           json.RawMessage
	Recommendations json.RawMessage
}

type httpStatusError int

func (e httpStatusError) Error() string {
	return fmt.Sprintf("marketplace HTTP status %d", int(e))
}

// Fetch resolves a source, downloads a bounded index, and asks Core to validate it.
// Caller supplies the actual host capabilities; Core alone determines availability.
func (s *Service) Fetch(ctx context.Context, input string, kind core.MarketplaceSourceKind, platform string, capabilities map[string][]int) (Snapshot, error) {
	source, err := s.core.ResolveMarketplaceSource(ctx, input)
	if err != nil {
		return Snapshot{}, err
	}
	pinned := s.pin(ctx, input, source)
	data, atCommit, err := s.fetchPinnedVersion(ctx, source.IndexURL, pinnedIndex(pinned))
	if err != nil {
		return Snapshot{}, err
	}
	index, err := s.core.ValidateMarketplaceIndex(ctx, json.RawMessage(data), kind, platform, capabilities)
	if err != nil {
		return Snapshot{}, err
	}
	deltasURL := source.DeltasURL
	if atCommit {
		deltasURL = pinned.DeltasURL
	}
	for i := range index.Plugins {
		index.Plugins[i].MarketplaceIndexURL = source.IndexURL
		index.Plugins[i].MarketplaceDeltasURL = deltasURL
	}
	return Snapshot{Source: source, Index: index}, nil
}

// FetchRecommendationBundle downloads the companion recommendations file first and returns
// ok=false without fetching the index when the marketplace publishes no recommendations (HTTP 404).
func (s *Service) FetchRecommendationBundle(ctx context.Context, input string, kind core.MarketplaceSourceKind) (RecommendationBundle, bool, error) {
	source, err := s.core.ResolveMarketplaceSource(ctx, input)
	if err != nil {
		return RecommendationBundle{}, false, err
	}
	if source.RecommendationsURL == "" {
		return RecommendationBundle{}, false, nil
	}
	pinned := s.pin(ctx, input, source)
	recBody, err := s.fetchPinned(ctx, source.RecommendationsURL, pinnedRecommendations(pinned))
	if err != nil {
		if err == httpStatusError(http.StatusNotFound) {
			return RecommendationBundle{}, false, nil
		}
		return RecommendationBundle{}, false, err
	}
	indexBody, err := s.fetchPinned(ctx, source.IndexURL, pinnedIndex(pinned))
	if err != nil {
		return RecommendationBundle{}, false, err
	}
	return RecommendationBundle{
		Source:          source,
		SourceKind:      kind,
		Index:           json.RawMessage(indexBody),
		Recommendations: json.RawMessage(recBody),
	}, true, nil
}

// pin asks for the newest commit of a GitHub-hosted source and has Core place the source's files
// at it. It returns nil, after reporting why, when the lookup or Core fails, and nil without a
// report when s does not pin or the source follows no GitHub branch.
func (s *Service) pin(ctx context.Context, input string, source core.MarketplaceSource) *core.MarketplacePinned {
	if s.latest == nil || source.Revision == nil {
		return nil
	}
	lookupCtx, cancel := context.WithTimeout(ctx, commitLookupTimeout)
	commit, err := s.latest(lookupCtx, source.Revision.Repository, source.Revision.Ref)
	cancel()
	if err != nil {
		s.reportFallback(ctx, fmt.Errorf("look up the newest commit of %s/%s %s: %w", source.Revision.Repository.Owner, source.Revision.Repository.Name, source.Revision.Ref, err))
		return nil
	}
	pinned, err := s.core.PinMarketplaceSource(ctx, input, commit)
	if err == nil && pinned.Pinned == nil {
		err = errors.New("Core placed no file at the commit")
	}
	if err != nil {
		s.reportFallback(ctx, fmt.Errorf("pin %s at %s: %w", source.IndexURL, commit, err))
		return nil
	}
	return pinned.Pinned
}

// fetchPinned reads the file at pinnedURL when there is one and at canonical otherwise. A pinned
// read that fails is reported and retried at canonical, except a 404: the commit is the
// repository's newest, so the file is absent from it.
func (s *Service) fetchPinned(ctx context.Context, canonical, pinnedURL string) ([]byte, error) {
	data, _, err := s.fetchPinnedVersion(ctx, canonical, pinnedURL)
	return data, err
}

// fetchPinnedVersion identifies the revision actually read, so optional companions
// can use that exact revision without falling back independently.
func (s *Service) fetchPinnedVersion(ctx context.Context, canonical, pinnedURL string) ([]byte, bool, error) {
	if pinnedURL != "" {
		data, _, err := s.fetchJSON(ctx, pinnedURL)
		if err == nil || err == httpStatusError(http.StatusNotFound) || ctx.Err() != nil {
			return data, true, err
		}
		s.reportFallback(ctx, fmt.Errorf("read %s: %w", pinnedURL, err))
	}
	data, _, err := s.fetchJSON(ctx, canonical)
	return data, false, err
}

func (s *Service) reportFallback(ctx context.Context, err error) {
	if s.fallback != nil {
		s.fallback(ctx, err)
	}
}

func pinnedIndex(pinned *core.MarketplacePinned) string {
	if pinned == nil {
		return ""
	}
	return pinned.IndexURL
}

func pinnedRecommendations(pinned *core.MarketplacePinned) string {
	if pinned == nil {
		return ""
	}
	return pinned.RecommendationsURL
}

func (s *Service) fetchJSON(ctx context.Context, rawURL string) (data []byte, status int, err error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
	if err != nil {
		return nil, 0, err
	}
	if !strings.EqualFold(request.URL.Scheme, "https") || request.URL.Host == "" || request.URL.User != nil {
		return nil, 0, ErrUnsafeRedirect
	}
	response, err := s.http.Do(request)
	if err != nil {
		return nil, 0, err
	}
	defer func() {
		if closeErr := response.Body.Close(); closeErr != nil {
			err = errors.Join(err, closeErr)
		}
	}()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return nil, response.StatusCode, httpStatusError(response.StatusCode)
	}
	if response.ContentLength > MaxIndexBytes {
		return nil, response.StatusCode, ErrIndexTooLarge
	}
	data, err = io.ReadAll(io.LimitReader(response.Body, MaxIndexBytes+1))
	if err != nil {
		return nil, response.StatusCode, err
	}
	if len(data) > MaxIndexBytes {
		return nil, response.StatusCode, ErrIndexTooLarge
	}
	if !json.Valid(data) {
		return nil, response.StatusCode, ErrInvalidJSON
	}
	return data, response.StatusCode, nil
}
