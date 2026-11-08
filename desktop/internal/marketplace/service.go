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
	// MaxIndexBytes matches the existing macOS market's index budget.
	MaxIndexBytes = 5 << 20
	fetchTimeout  = 20 * time.Second
	maxRedirects  = 10
)

var (
	ErrIndexTooLarge  = errors.New("marketplace index exceeds the size limit")
	ErrInvalidJSON    = errors.New("marketplace index is not valid JSON")
	ErrUnsafeRedirect = errors.New("marketplace redirect is not a safe HTTPS URL")
)

// Evaluator is the shared Core marketplace contract, supplied by core.Client.
type Evaluator interface {
	ResolveMarketplaceSource(context.Context, string) (core.MarketplaceSource, error)
	ValidateMarketplaceIndex(context.Context, json.RawMessage, core.MarketplaceSourceKind, string, map[string][]int) (core.MarketplaceIndex, error)
}

// Service holds a reusable HTTP client. It stores no index inside application resources.
type Service struct {
	core Evaluator
	http *http.Client
}

// New creates a marketplace service. A nil client uses Go's default transport;
// a client can be supplied to apply product network policy or test offline.
func New(evaluator Evaluator, client *http.Client) *Service {
	if client == nil {
		client = &http.Client{}
	}
	copy := *client
	if copy.Timeout == 0 || copy.Timeout > fetchTimeout {
		copy.Timeout = fetchTimeout
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
	return &Service{core: evaluator, http: &copy}
}

// Snapshot pairs a validated catalog with the canonical source that produced it.
type Snapshot struct {
	Source core.MarketplaceSource
	Index  core.MarketplaceIndex
}

// Fetch resolves a source, downloads a bounded index, and asks Core to validate it.
// Caller supplies the actual host capabilities; Core alone determines availability.
func (s *Service) Fetch(ctx context.Context, input string, kind core.MarketplaceSourceKind, platform string, capabilities map[string][]int) (snapshot Snapshot, err error) {
	source, err := s.core.ResolveMarketplaceSource(ctx, input)
	if err != nil {
		return Snapshot{}, err
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, source.IndexURL, nil)
	if err != nil {
		return Snapshot{}, err
	}
	if !strings.EqualFold(request.URL.Scheme, "https") || request.URL.Host == "" || request.URL.User != nil {
		return Snapshot{}, ErrUnsafeRedirect
	}
	response, err := s.http.Do(request)
	if err != nil {
		return Snapshot{}, err
	}
	defer func() { err = errors.Join(err, response.Body.Close()) }()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return Snapshot{}, fmt.Errorf("marketplace HTTP status %d", response.StatusCode)
	}
	if response.ContentLength > MaxIndexBytes {
		return Snapshot{}, ErrIndexTooLarge
	}
	data, err := io.ReadAll(io.LimitReader(response.Body, MaxIndexBytes+1))
	if err != nil {
		return Snapshot{}, err
	}
	if len(data) > MaxIndexBytes {
		return Snapshot{}, ErrIndexTooLarge
	}
	if !json.Valid(data) {
		return Snapshot{}, ErrInvalidJSON
	}
	index, err := s.core.ValidateMarketplaceIndex(ctx, json.RawMessage(data), kind, platform, capabilities)
	if err != nil {
		return Snapshot{}, err
	}
	return Snapshot{Source: source, Index: index}, nil
}
