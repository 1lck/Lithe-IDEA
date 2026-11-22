package marketplace

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/contractfixture"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

type transportFunc func(*http.Request) (*http.Response, error)

func (f transportFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestFetchValidatesIndexThroughCore(t *testing.T) {
	index, err := os.ReadFile(contractfixture.Path("fixtures/marketplace/index.json"))
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
	for _, plugin := range result.Index.Plugins {
		if plugin.MarketplaceIndexURL == "" || plugin.MarketplaceIndexURL != result.Source.IndexURL {
			t.Fatalf("plugin %q source = %q, want %q", plugin.ID, plugin.MarketplaceIndexURL, result.Source.IndexURL)
		}
		data, marshalErr := json.Marshal(plugin)
		if marshalErr != nil || strings.Contains(string(data), "marketplaceIndexURL") {
			t.Fatalf("native-only provenance leaked into Core JSON: %s, error = %v", data, marshalErr)
		}
	}
}

func TestFetchCurrentOfficialEmptyIndex(t *testing.T) {
	if OfficialIndexURL != "https://raw.githubusercontent.com/1lck/Lithe-IDEA/HEAD/Plugins/marketplace/index.json" {
		t.Fatalf("official index is not the current main repository: %s", OfficialIndexURL)
	}
	index, err := os.ReadFile("../core/testdata/marketplace/lithe-official-index.json")
	if err != nil {
		t.Fatal(err)
	}
	const url = OfficialIndexURL
	client := &http.Client{Transport: transportFunc(func(r *http.Request) (*http.Response, error) {
		if r.URL.String() != url {
			t.Errorf("URL = %s", r.URL)
		}
		return &http.Response{StatusCode: 200, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(string(index))), Request: r}, nil
	})}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	snapshot, err := New(core.NewClient(), client).Fetch(ctx, url, core.MarketplaceOfficial, strings.Join([]string{"darwin", "arm64"}, "-"), map[string][]int{})
	if err != nil {
		t.Fatal(err)
	}
	if len(snapshot.Index.Plugins) != 0 || len(snapshot.Index.Rejected) != 0 {
		t.Fatalf("official index = %+v", snapshot.Index)
	}
}

// The published official URL points into this repository's default branch.
// Deleting that file from the replacement client would make it return 404
// after the branch containing the deletion reaches the default branch.
func TestPublishedOfficialIndexExistsInRepository(t *testing.T) {
	data, err := os.ReadFile("../../../Plugins/marketplace/index.json")
	if err != nil {
		t.Fatalf("official marketplace endpoint has no repository source: %v", err)
	}
	var index struct {
		SchemaVersion int               `json:"schemaVersion"`
		Plugins       []json.RawMessage `json:"plugins"`
	}
	if err := json.Unmarshal(data, &index); err != nil || index.SchemaVersion != 1 || index.Plugins == nil {
		t.Fatalf("official marketplace source is not a version 1 index: %v", err)
	}
}

func TestFetchOfficialSourceKeepsOfficialNamespace(t *testing.T) {
	index, err := os.ReadFile(contractfixture.Path("fixtures/marketplace/index.json"))
	if err != nil {
		t.Fatal(err)
	}
	client := &http.Client{Transport: transportFunc(func(r *http.Request) (*http.Response, error) {
		return &http.Response{StatusCode: 200, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(string(index))), Request: r}, nil
	})}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	snapshot, err := New(core.NewClient(), client).Fetch(ctx, OfficialIndexURL, core.MarketplaceOfficial, strings.Join([]string{"darwin", "arm64"}, "-"), map[string][]int{})
	if err != nil {
		t.Fatal(err)
	}
	for _, plugin := range snapshot.Index.Plugins {
		if strings.HasPrefix(plugin.ID, "dev.lithe.") {
			return
		}
	}
	t.Fatal("official namespace was not retained for the official source")
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
	index, err := os.ReadFile(contractfixture.Path("fixtures/marketplace/index.json"))
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

func TestFetchRecommendationBundle(t *testing.T) {
	index, err := os.ReadFile(contractfixture.Path("fixtures/marketplace/index.json"))
	if err != nil {
		t.Fatal(err)
	}
	recommendations, err := os.ReadFile(contractfixture.Path("fixtures/marketplace/recommendations.json"))
	if err != nil {
		t.Fatal(err)
	}

	t.Run("downloads companion recommendations and index", func(t *testing.T) {
		var requested []string
		client := &http.Client{Transport: transportFunc(func(r *http.Request) (*http.Response, error) {
			requested = append(requested, r.URL.String())
			switch r.URL.String() {
			case "https://raw.githubusercontent.com/example/lithe-plugins/HEAD/lithe-plugin-recommendations.json":
				return &http.Response{StatusCode: 200, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(string(recommendations))), Request: r}, nil
			case "https://raw.githubusercontent.com/example/lithe-plugins/HEAD/lithe-plugin-index.json":
				return &http.Response{StatusCode: 200, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(string(index))), Request: r}, nil
			default:
				return &http.Response{StatusCode: 404, Header: make(http.Header), Body: io.NopCloser(strings.NewReader("")), Request: r}, nil
			}
		})}
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		bundle, ok, fetchErr := New(core.NewClient(), client).FetchRecommendationBundle(ctx, "https://github.com/example/lithe-plugins", core.MarketplaceThirdParty)
		if fetchErr != nil || !ok {
			t.Fatalf("FetchRecommendationBundle = (%v, %v)", ok, fetchErr)
		}
		if len(requested) != 2 || len(bundle.Recommendations) == 0 || len(bundle.Index) == 0 {
			t.Fatalf("requested = %v, bundle sizes = (%d, %d)", requested, len(bundle.Recommendations), len(bundle.Index))
		}
	})

	t.Run("skips silently on 404 recommendations without fetching index", func(t *testing.T) {
		var requested []string
		client := &http.Client{Transport: transportFunc(func(r *http.Request) (*http.Response, error) {
			requested = append(requested, r.URL.String())
			return &http.Response{StatusCode: 404, Header: make(http.Header), Body: io.NopCloser(strings.NewReader("")), Request: r}, nil
		})}
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_, ok, fetchErr := New(core.NewClient(), client).FetchRecommendationBundle(ctx, "https://github.com/example/lithe-plugins", core.MarketplaceThirdParty)
		if fetchErr != nil || ok {
			t.Fatalf("FetchRecommendationBundle on 404 = (%v, %v), want (false, nil)", ok, fetchErr)
		}
		if len(requested) != 1 || !strings.HasSuffix(requested[0], "/lithe-plugin-recommendations.json") {
			t.Fatalf("requested = %v, expected only recommendations URL", requested)
		}
	})

	t.Run("rejects invalid JSON or oversized recommendations", func(t *testing.T) {
		for _, tc := range []struct {
			name, body string
			want       error
		}{
			{"invalid", "not-json", ErrInvalidJSON},
			{"oversized", strings.Repeat("x", MaxIndexBytes+1), ErrIndexTooLarge},
		} {
			t.Run(tc.name, func(t *testing.T) {
				client := &http.Client{Transport: transportFunc(func(r *http.Request) (*http.Response, error) {
					return &http.Response{StatusCode: 200, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(tc.body)), Request: r}, nil
				})}
				ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
				defer cancel()
				_, _, fetchErr := New(core.NewClient(), client).FetchRecommendationBundle(ctx, "https://plugins.example.com/index.json", core.MarketplaceThirdParty)
				if !errors.Is(fetchErr, tc.want) {
					t.Fatalf("error = %v, want %v", fetchErr, tc.want)
				}
			})
		}
	})
}

// pinTestCommit is the newest commit the pinning tests' lookup reports.
const pinTestCommit = "0123456789abcdef0123456789abcdef01234567"

func TestFetchReadsGitHubIndexAtNewestCommit(t *testing.T) {
	index, err := os.ReadFile(contractfixture.Path("fixtures/marketplace/index.json"))
	if err != nil {
		t.Fatal(err)
	}
	const pinned = "https://raw.githubusercontent.com/example/lithe-plugins/" + pinTestCommit + "/lithe-plugin-index.json"
	var requested []string
	client := &http.Client{Transport: transportFunc(func(r *http.Request) (*http.Response, error) {
		requested = append(requested, r.URL.String())
		return &http.Response{StatusCode: 200, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(string(index))), Request: r}, nil
	})}
	var looked []string
	var reported []error
	service := New(core.NewClient(), client).PinToLatestCommit(func(_ context.Context, repository core.GitHubRepo, ref string) (string, error) {
		looked = append(looked, repository.Owner+"/"+repository.Name+"@"+ref)
		return pinTestCommit, nil
	}, func(_ context.Context, err error) { reported = append(reported, err) })
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	snapshot, err := service.Fetch(ctx, "https://github.com/example/lithe-plugins", core.MarketplaceThirdParty, "darwin-arm64", map[string][]int{})
	if err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(looked, []string{"example/lithe-plugins@HEAD"}) || !slices.Equal(requested, []string{pinned}) || len(reported) != 0 {
		t.Fatalf("looked up %v, requested %v, reported %v", looked, requested, reported)
	}
	// The source keeps its branch URL: trust records and automatic updates match on it.
	const canonical = "https://raw.githubusercontent.com/example/lithe-plugins/HEAD/lithe-plugin-index.json"
	if snapshot.Source.IndexURL != canonical {
		t.Fatalf("source = %s", snapshot.Source.IndexURL)
	}
	for _, plugin := range snapshot.Index.Plugins {
		if plugin.MarketplaceIndexURL != canonical {
			t.Fatalf("plugin %q source = %q", plugin.ID, plugin.MarketplaceIndexURL)
		}
	}
}

func TestFetchFallsBackToBranchIndexAndReports(t *testing.T) {
	index, err := os.ReadFile(contractfixture.Path("fixtures/marketplace/index.json"))
	if err != nil {
		t.Fatal(err)
	}
	const canonical = "https://raw.githubusercontent.com/example/lithe-plugins/HEAD/lithe-plugin-index.json"
	const pinned = "https://raw.githubusercontent.com/example/lithe-plugins/" + pinTestCommit + "/lithe-plugin-index.json"
	for _, tc := range []struct {
		name      string
		lookupErr error
		pinnedOK  bool
		want      []string
	}{
		{name: "lookup fails", lookupErr: errors.New("rate limited"), want: []string{canonical}},
		{name: "pinned read fails", pinnedOK: false, want: []string{pinned, canonical}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var requested []string
			client := &http.Client{Transport: transportFunc(func(r *http.Request) (*http.Response, error) {
				requested = append(requested, r.URL.String())
				if r.URL.String() == pinned && !tc.pinnedOK {
					return &http.Response{StatusCode: 503, Header: make(http.Header), Body: io.NopCloser(strings.NewReader("")), Request: r}, nil
				}
				return &http.Response{StatusCode: 200, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(string(index))), Request: r}, nil
			})}
			var reported []error
			service := New(core.NewClient(), client).PinToLatestCommit(func(context.Context, core.GitHubRepo, string) (string, error) {
				return pinTestCommit, tc.lookupErr
			}, func(_ context.Context, err error) { reported = append(reported, err) })
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			if _, err := service.Fetch(ctx, "https://github.com/example/lithe-plugins", core.MarketplaceThirdParty, "darwin-arm64", map[string][]int{}); err != nil {
				t.Fatal(err)
			}
			if !slices.Equal(requested, tc.want) || len(reported) != 1 {
				t.Fatalf("requested %v, reported %v", requested, reported)
			}
		})
	}
}

func TestFetchDoesNotLookUpSourcesOutsideGitHub(t *testing.T) {
	index, err := os.ReadFile(contractfixture.Path("fixtures/marketplace/index.json"))
	if err != nil {
		t.Fatal(err)
	}
	client := &http.Client{Transport: transportFunc(func(r *http.Request) (*http.Response, error) {
		return &http.Response{StatusCode: 200, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(string(index))), Request: r}, nil
	})}
	service := New(core.NewClient(), client).PinToLatestCommit(func(context.Context, core.GitHubRepo, string) (string, error) {
		t.Error("a source outside GitHub was looked up")
		return "", errors.New("unexpected lookup")
	}, func(_ context.Context, err error) { t.Errorf("reported %v", err) })
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if _, err := service.Fetch(ctx, "https://plugins.example.com/index.json", core.MarketplaceThirdParty, "darwin-arm64", map[string][]int{}); err != nil {
		t.Fatal(err)
	}
}
