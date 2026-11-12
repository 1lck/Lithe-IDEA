package core

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestDocumentTextClassificationUsesSharedFixtures(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("..", "..", "..", "shared", "fixtures", "editor", "text-content-v1.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Cases []struct {
			Name        string `json:"name"`
			Text        string `json:"text"`
			IsPlainText bool   `json:"isPlainText"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	for _, item := range fixture.Cases {
		t.Run(item.Name, func(t *testing.T) {
			kind, err := ClassifyDocumentText([]byte(item.Text))
			want := DocumentBinary
			if item.IsPlainText {
				want = DocumentPlainText
			}
			if err != nil || kind != want {
				t.Fatalf("classification = %v, error %v; want %v", kind, err, want)
			}
		})
	}
	if kind, err := ClassifyDocumentText([]byte{0xd6, 0xd0}); err != nil || kind != DocumentInvalidUTF8 {
		t.Fatalf("invalid UTF-8 classification = %v, error %v", kind, err)
	}
}
