package marketplace

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

type transportFunc func(*http.Request) (*http.Response, error)

func (f transportFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestFetchValidatesIndexThroughCore(t *testing.T) {
	index, err := os.ReadFile("../../../shared/contracts/plugins/v1/fixtures/marketplace/index.json")
	if err != nil {
		t.Fatal(err)
	}
	client := &http.Client{Transport: transportFunc(func(r *http.Request) (*http.Response, error) {
		if r.URL.String() != "https://raw.githubusercontent.com/example/lithe-plugins/HEAD/lithe-plugin-index.json" {
			t.Errorf("URL = %s", r.URL)
		}
		return &http.Response{StatusCode: 200, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(string(index))), Request: r}, nil
	})}
	service := New(core.NewClient(), client)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	result, err := service.Fetch(ctx, "https://github.com/example/lithe-plugins", core.MarketplaceThirdParty, "darwin-arm64", map[string][]int{})
	if err != nil || len(result.Index.Plugins) != 3 || len(result.Index.Rejected) != 2 {
		t.Fatalf("result = %#v, error = %v", result, err)
	}
}

func TestFetchRejectsOversizedAndInvalidIndexes(t *testing.T) {
	for _, tc := range []struct {
		name, body string
		want       error
	}{{"large", strings.Repeat("x", MaxIndexBytes+1), ErrIndexTooLarge}, {"invalid", "not-json", ErrInvalidJSON}} {
		t.Run(tc.name, func(t *testing.T) {
			client := &http.Client{Transport: transportFunc(func(r *http.Request) (*http.Response, error) {
				return &http.Response{StatusCode: 200, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(tc.body)), Request: r}, nil
			})}
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			_, err := New(core.NewClient(), client).Fetch(ctx, "https://plugins.example.com/index.json", core.MarketplaceThirdParty, "darwin-arm64", nil)
			if !errors.Is(err, tc.want) {
				t.Fatalf("error = %v, want %v", err, tc.want)
			}
		})
	}
}

func TestFetchRejectsInsecureRedirect(t *testing.T) {
	client := &http.Client{Transport: transportFunc(func(r *http.Request) (*http.Response, error) {
		return &http.Response{StatusCode: 302, Header: http.Header{"Location": []string{"http://example.com/index.json"}}, Body: io.NopCloser(strings.NewReader("")), Request: r}, nil
	})}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_, err := New(core.NewClient(), client).Fetch(ctx, "https://plugins.example.com/index.json", core.MarketplaceThirdParty, "darwin-arm64", nil)
	if !errors.Is(err, ErrUnsafeRedirect) {
		t.Fatalf("error = %v", err)
	}
}

func TestFetchReturnsCoreRejection(t *testing.T) {
	data, err := json.Marshal(map[string]any{"schemaVersion": 99, "plugins": []any{}})
	if err != nil {
		t.Fatal(err)
	}
	client := &http.Client{Transport: transportFunc(func(r *http.Request) (*http.Response, error) {
		return &http.Response{StatusCode: 200, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(string(data))), Request: r}, nil
	})}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_, err = New(core.NewClient(), client).Fetch(ctx, "https://plugins.example.com/index.json", core.MarketplaceThirdParty, "darwin-arm64", nil)
	var rejection *core.MarketplaceRejection
	if !errors.As(err, &rejection) || rejection.Code != "plugin.index.schemaUnsupported" {
		t.Fatalf("error = %#v", err)
	}
}

type failingCloseBody struct{ io.Reader }

func (failingCloseBody) Close() error { return errCloseBody }

var errCloseBody = errors.New("injected close failure")

func TestFetchReportsResponseCloseFailure(t *testing.T) {
	index, err := os.ReadFile("../../../shared/contracts/plugins/v1/fixtures/marketplace/index.json")
	if err != nil {
		t.Fatal(err)
	}
	client := &http.Client{Transport: transportFunc(func(r *http.Request) (*http.Response, error) {
		return &http.Response{StatusCode: 200, Header: make(http.Header), Body: failingCloseBody{strings.NewReader(string(index))}, Request: r}, nil
	})}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_, err = New(core.NewClient(), client).Fetch(ctx, "https://plugins.example.com/index.json", core.MarketplaceThirdParty, "darwin-arm64", nil)
	if !errors.Is(err, errCloseBody) {
		t.Fatalf("error = %v, want close error", err)
	}
}

func TestFetchStopsWhenRequestIsCancelled(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	client := &http.Client{Transport: transportFunc(func(r *http.Request) (*http.Response, error) {
		t.Error("cancelled operation reached the network")
		return nil, errors.New("unexpected request")
	})}
	_, err := New(core.NewClient(), client).Fetch(ctx, "https://plugins.example.com/index.json", core.MarketplaceThirdParty, "darwin-arm64", nil)
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("error = %v, want context cancellation", err)
	}
}
