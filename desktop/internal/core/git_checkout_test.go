package core

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestCheckoutMetadataUsesSharedFixture(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("..", "..", "..", "shared", "fixtures", "git", "checkout-metadata-v1.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Cases []struct {
			Command  string `json:"command"`
			Text     string `json:"text"`
			Expected struct {
				Branch *string `json:"branch"`
				Path   *string `json:"path"`
			} `json:"expected"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	client := NewClient()
	for _, tc := range fixture.Cases {
		t.Run(tc.Command+"/"+tc.Text, func(t *testing.T) {
			var got string
			var want *string
			var err error
			switch tc.Command {
			case "git.parseCheckoutMetadata":
				got, err = client.GitCheckoutBranch(context.Background(), tc.Text)
				want = tc.Expected.Branch
			case "git.parseGitdirPointer":
				got, err = client.GitDirectoryPointer(context.Background(), tc.Text)
				want = tc.Expected.Path
			default:
				t.Fatalf("unknown fixture command %q", tc.Command)
			}
			expected := ""
			if want != nil {
				expected = *want
			}
			if err != nil || got != expected {
				t.Fatalf("got %q, %v; want %q", got, err, expected)
			}
		})
	}
	if _, err := client.GitCheckoutBranch(context.Background(), strings.Repeat("x", 4097)); err == nil {
		t.Fatal("Core accepted metadata larger than its published limit")
	}
}
