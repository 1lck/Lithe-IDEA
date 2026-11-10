package core

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"
)

func readRunFixture(t *testing.T, name string) []byte {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("..", "..", "..", "shared", "contracts", "plugins", "v1", "fixtures", "run", name))
	if err != nil {
		t.Fatal(err)
	}
	return data
}

// TestMatchOutputLinksFollowsTheContractFixture replays the shared fixture
// through the client: Core decides every link, the client only carries it.
func TestMatchOutputLinksFollowsTheContractFixture(t *testing.T) {
	var fixture struct {
		Match []struct {
			Name    string            `json:"name"`
			Request OutputLinkRequest `json:"request"`
			Links   []OutputLink      `json:"links"`
		} `json:"match"`
	}
	if err := json.Unmarshal(readRunFixture(t, "output-link-matchers.json"), &fixture); err != nil {
		t.Fatal(err)
	}
	if len(fixture.Match) == 0 {
		t.Fatal("the fixture has no match cases")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	for _, test := range fixture.Match {
		t.Run(test.Name, func(t *testing.T) {
			links, err := NewClient().MatchOutputLinks(ctx, test.Request)
			if err != nil {
				t.Fatal(err)
			}
			if len(links) == 0 && len(test.Links) == 0 {
				return
			}
			// Compare as JSON values: the groups are raw text whose spacing is Core's.
			var got, want any
			gotBytes, _ := json.Marshal(links)
			wantBytes, _ := json.Marshal(test.Links)
			if err := json.Unmarshal(gotBytes, &got); err != nil {
				t.Fatal(err)
			}
			if err := json.Unmarshal(wantBytes, &want); err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(got, want) {
				t.Fatalf("links = %s, want %s", gotBytes, wantBytes)
			}
		})
	}
}

func TestDecodeOutputLinkResolutionFollowsTheContractFixture(t *testing.T) {
	var fixture struct {
		Resolution []struct {
			Name     string          `json:"name"`
			Reply    json.RawMessage `json:"reply"`
			Location *OutputLocation `json:"location"`
			Invalid  bool            `json:"invalid"`
		} `json:"resolution"`
	}
	if err := json.Unmarshal(readRunFixture(t, "output-link-matchers.json"), &fixture); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	for _, test := range fixture.Resolution {
		t.Run(test.Name, func(t *testing.T) {
			location, err := NewClient().DecodeOutputLinkResolution(ctx, test.Reply)
			if test.Invalid {
				if err == nil {
					t.Fatalf("a reply %s was accepted: %+v", test.Reply, location)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(location, test.Location) {
				t.Fatalf("location = %+v, want %+v", location, test.Location)
			}
		})
	}
}
