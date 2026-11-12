package core

import (
	"encoding/json"
	"github.com/1lck/Lithe-IDEA/desktop/internal/contractfixture"
	"os"
	"path/filepath"
	"testing"
)

// readMarketFixture uses the shared fixtures of the pinned Core contract.
func readMarketFixture(t *testing.T, name string, value any) {
	t.Helper()
	data, err := os.ReadFile(contractfixture.Path("fixtures/" + name))
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(data, value); err != nil {
		t.Fatal(err)
	}
}

func TestMarketplaceSourceFixture(t *testing.T) {
	var fixture struct {
		Cases []struct {
			Input    string `json:"input"`
			Expected struct {
				IndexURL    string `json:"indexURL"`
				DisplayName string `json:"displayName"`
			} `json:"expected"`
			ExpectedCode string `json:"expectedCode"`
		} `json:"cases"`
	}
	readMarketFixture(t, "marketplace/source-urls.json", &fixture)
	client := NewClient()
	for _, item := range fixture.Cases {
		t.Run(item.Input, func(t *testing.T) {
			source, err := client.ResolveMarketplaceSource(testContext(t), item.Input)
			if item.ExpectedCode != "" {
				rejection, ok := err.(*MarketplaceRejection)
				if !ok || rejection.Code != item.ExpectedCode {
					t.Fatalf("rejection = %#v; want %s", err, item.ExpectedCode)
				}
				return
			}
			if err != nil || source.IndexURL != item.Expected.IndexURL || source.DisplayName != item.Expected.DisplayName {
				t.Fatalf("source = %#v, error = %v", source, err)
			}
		})
	}
}

func TestMarketplaceIndexFixture(t *testing.T) {
	var index json.RawMessage
	readMarketFixture(t, "marketplace/index.json", &index)
	var fixture struct {
		Cases []struct {
			Name             string                `json:"name"`
			SourceKind       MarketplaceSourceKind `json:"sourceKind"`
			Platform         string                `json:"platform"`
			HostCapabilities map[string][]int      `json:"hostCapabilities"`
			Expected         struct {
				Plugins []struct {
					ID           string `json:"id"`
					Availability struct {
						Status string `json:"status"`
						Code   string `json:"code"`
					} `json:"availability"`
				} `json:"plugins"`
				Rejected []struct {
					ID   string `json:"id"`
					Code string `json:"code"`
				} `json:"rejected"`
			} `json:"expected"`
		} `json:"cases"`
	}
	readMarketFixture(t, "marketplace/index-cases.json", &fixture)
	client := NewClient()
	for _, item := range fixture.Cases {
		t.Run(item.Name, func(t *testing.T) {
			result, err := client.ValidateMarketplaceIndex(testContext(t), index, item.SourceKind, item.Platform, item.HostCapabilities)
			if err != nil {
				t.Fatal(err)
			}
			if len(result.Plugins) != len(item.Expected.Plugins) || len(result.Rejected) != len(item.Expected.Rejected) {
				t.Fatalf("index = %#v", result)
			}
			for i, expected := range item.Expected.Plugins {
				got := result.Plugins[i]
				if got.ID != expected.ID || got.Availability.Status != expected.Availability.Status || got.Availability.Code != expected.Availability.Code {
					t.Errorf("plugin[%d] = %#v, want %#v", i, got, expected)
				}
			}
			for i, expected := range item.Expected.Rejected {
				got := result.Rejected[i]
				if got.ID == nil || *got.ID != expected.ID || got.Error.Code != expected.Code {
					t.Errorf("rejection[%d] = %#v, want %#v", i, got, expected)
				}
			}
		})
	}
}

// An empty host capability table must not be omitted: Core's default means its own
// capabilities, which the new desktop host has not implemented yet.
func TestMarketplaceReviewRejectsMissingHostCapabilities(t *testing.T) {
	var manifest json.RawMessage
	readMarketFixture(t, "build-providers/build-provider-language-server.plugin.json", &manifest)
	_, err := NewClient().ReviewMarketplaceInstall(testContext(t), manifest, "", "", nil, map[string][]int{})
	rejection, ok := err.(*MarketplaceRejection)
	if !ok || rejection.Code != "plugin.api.unsupported" {
		t.Fatalf("error = %#v; want unsupported host", err)
	}
}

// The Store fixture is the public community index at Lithe-store revision
// 53676c51c756d8ead093053f0128735626ff64ec (Apache-2.0), written in contract
// v2 form: every level and capability version is 0.
func TestMarketplaceValidatesCommunityStore(t *testing.T) {
	index, err := os.ReadFile(filepath.Join("testdata", "marketplace", "lithe-store-index.json"))
	if err != nil {
		t.Fatal(err)
	}
	result, err := NewClient().ValidateMarketplaceIndex(testContext(t), index, MarketplaceThirdParty, "darwin-arm64", map[string][]int{})
	if err != nil {
		t.Fatal(err)
	}
	if len(result.Rejected) != 0 || len(result.Plugins) != 12 {
		t.Fatalf("plugins = %d, rejected = %#v", len(result.Plugins), result.Rejected)
	}
	for _, entry := range result.Plugins {
		if entry.ID == "io.github.lithe-idea.maven-build" && entry.Availability.Status != "unsupported" {
			t.Fatalf("Maven must not be offered without its host: %#v", entry.Availability)
		}
	}
}
