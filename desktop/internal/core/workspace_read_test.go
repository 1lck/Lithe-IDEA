package core

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/contractfixture"
)

func TestWorkspaceReadsFollowTheLinkedCoreByteFixture(t *testing.T) {
	data, err := os.ReadFile(contractfixture.CoreFixture("workspace/read-v1.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Files []struct {
			ID           string
			Bytes        []byte
			MaximumBytes *int
			Expected     map[string]json.RawMessage
		}
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	if len(fixture.Files) == 0 {
		t.Fatal("the linked Core fixture has no file cases")
	}
	client := NewClient()
	root := t.TempDir()
	for _, test := range fixture.Files {
		t.Run(test.ID, func(t *testing.T) {
			if err := os.WriteFile(filepath.Join(root, "input"), test.Bytes, 0o600); err != nil {
				t.Fatal(err)
			}
			ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
			defer cancel()
			file, err := client.ReadWorkspaceFile(ctx, root, "input", test.MaximumBytes)
			if err != nil {
				t.Fatal(err)
			}
			encoded, err := json.Marshal(file)
			if err != nil {
				t.Fatal(err)
			}
			var actual map[string]json.RawMessage
			if err := json.Unmarshal(encoded, &actual); err != nil {
				t.Fatal(err)
			}
			for key, expected := range test.Expected {
				var got, want any
				if err := json.Unmarshal(actual[key], &got); err != nil {
					t.Fatalf("%s: %v", key, err)
				}
				if err := json.Unmarshal(expected, &want); err != nil {
					t.Fatal(err)
				}
				if !reflect.DeepEqual(got, want) {
					t.Errorf("%s = %v, want %v", key, got, want)
				}
			}
			if (file.Text == nil) == (file.Base64 == nil) {
				t.Fatalf("read must contain exactly one of text/base64: %+v", file)
			}
		})
	}
}
