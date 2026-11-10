package core

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
)

func TestRenderMarkdownSharedFixture(t *testing.T) {
	data, err := os.ReadFile("../../../shared/fixtures/editor/markdown-render-v1.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Cases []struct {
			Name             string
			Source           string
			Contains, Absent []string
		}
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	client := NewClient()
	for _, c := range fixture.Cases {
		t.Run(c.Name, func(t *testing.T) {
			html, err := client.RenderMarkdown(testContext(t), c.Source)
			if err != nil {
				t.Fatal(err)
			}
			for _, want := range c.Contains {
				if !strings.Contains(html, want) {
					t.Errorf("html lacks %q:\n%s", want, html)
				}
			}
			for _, bad := range c.Absent {
				if strings.Contains(html, bad) {
					t.Errorf("html has %q:\n%s", bad, html)
				}
			}
		})
	}
}
