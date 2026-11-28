package core

import (
	"encoding/json"
	"os"
	"slices"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/contractfixture"
)

func TestFileTypeMappingsSharedFixture(t *testing.T) {
	data, err := os.ReadFile(contractfixture.CoreFixture("editor/file-type-mappings-v1.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Version             int `json:"version"`
		MaxMappingsPerScope int `json:"maxMappingsPerScope"`
		NormalizeCases      []struct {
			Name    string `json:"name"`
			Payload struct {
				Global           []FileTypeMapping `json:"global"`
				Project          []FileTypeMapping `json:"project"`
				KnownLanguageIDs []string          `json:"knownLanguageIDs"`
			} `json:"payload"`
			ExpectedGlobal  []FileTypeMapping      `json:"expectedGlobal"`
			ExpectedProject []FileTypeMapping      `json:"expectedProject"`
			ExpectedIssues  []FileTypeMappingIssue `json:"expectedIssues"`
		} `json:"normalizeCases"`
		ResolveCases []struct {
			Name    string `json:"name"`
			Payload struct {
				Path    string            `json:"path"`
				Global  []FileTypeMapping `json:"global"`
				Project []FileTypeMapping `json:"project"`
			} `json:"payload"`
			Expected ResolvedFileTypeMapping `json:"expected"`
		} `json:"resolveCases"`
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	if fixture.Version != 1 || len(fixture.NormalizeCases) == 0 || len(fixture.ResolveCases) == 0 {
		t.Fatal("invalid file type mappings fixture")
	}

	client := NewClient()
	ctx := testContext(t)

	for _, tc := range fixture.NormalizeCases {
		t.Run("normalize/"+tc.Name, func(t *testing.T) {
			got, err := client.NormalizeFileTypeMappings(ctx, tc.Payload.Global, tc.Payload.Project, tc.Payload.KnownLanguageIDs)
			if err != nil {
				t.Fatal(err)
			}
			if len(got.Builtins) == 0 {
				t.Fatal("expected built-in file type mappings")
			}
			if !slices.Equal(got.Global, tc.ExpectedGlobal) {
				t.Fatalf("global = %+v, want %+v", got.Global, tc.ExpectedGlobal)
			}
			if !slices.Equal(got.Project, tc.ExpectedProject) {
				t.Fatalf("project = %+v, want %+v", got.Project, tc.ExpectedProject)
			}
			if !slices.Equal(got.Issues, tc.ExpectedIssues) {
				t.Fatalf("issues = %+v, want %+v", got.Issues, tc.ExpectedIssues)
			}
		})
	}

	for _, tc := range fixture.ResolveCases {
		t.Run("resolve/"+tc.Name, func(t *testing.T) {
			got, err := client.ResolveFileTypeMapping(ctx, tc.Payload.Path, tc.Payload.Global, tc.Payload.Project, true)
			if err != nil {
				t.Fatal(err)
			}
			if got != tc.Expected {
				t.Fatalf("resolved = %+v, want %+v", got, tc.Expected)
			}
		})
	}
}
