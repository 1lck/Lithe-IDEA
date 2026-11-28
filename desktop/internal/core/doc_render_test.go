package core

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"slices"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/contractfixture"
)

type docRenderFixture struct {
	Version     int `json:"version"`
	DocComments []struct {
		Name                 string   `json:"name"`
		ShellKind            string   `json:"shellKind"`
		Dialect              string   `json:"dialect"`
		Language             string   `json:"language"`
		Source               string   `json:"source"`
		ExpectFallback       bool     `json:"expectFallback"`
		ExpectFallbackReason string   `json:"expectFallbackReason"`
		ExpectAnchors        []string `json:"expectAnchors"`
		ExpectBlockKinds     []string `json:"expectBlockKinds"`
		ForbidSubstrings     []string `json:"forbidSubstrings"`
	} `json:"docComments"`
	HoverDocs []struct {
		Name                 string   `json:"name"`
		IsMarkdown           bool     `json:"isMarkdown"`
		Language             string   `json:"language"`
		Contents             string   `json:"contents"`
		ExpectFallback       bool     `json:"expectFallback"`
		ExpectFallbackReason string   `json:"expectFallbackReason"`
		ExpectBlockKinds     []string `json:"expectBlockKinds"`
		ExpectFirstCodeText  string   `json:"expectFirstCodeText"`
		ExpectSubstrings     []string `json:"expectSubstrings"`
		ForbidSubstrings     []string `json:"forbidSubstrings"`
	} `json:"hoverDocs"`
}

func loadDocRenderFixture(t *testing.T) docRenderFixture {
	t.Helper()
	data, err := os.ReadFile(contractfixture.CoreFixture("editor/doc-render-v1.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fixture docRenderFixture
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	if len(fixture.DocComments) == 0 || len(fixture.HoverDocs) == 0 {
		t.Fatalf("doc-render-v1.json missing test vectors: %+v", fixture)
	}
	return fixture
}

func TestDocRenderContractFixtureAgainstCoreABI(t *testing.T) {
	fixture := loadDocRenderFixture(t)
	c := NewClient()
	ctx := context.Background()

	for _, tc := range fixture.DocComments {
		t.Run("docComment/"+tc.Name, func(t *testing.T) {
			res, err := c.RenderDocComment(ctx, []byte(tc.Source), tc.ShellKind, tc.Dialect, tc.Language)
			if err != nil {
				t.Fatalf("RenderDocComment failed: %v", err)
			}
			if res.FallbackToSource != tc.ExpectFallback {
				t.Fatalf("FallbackToSource = %v, want %v (reason=%q)", res.FallbackToSource, tc.ExpectFallback, res.FallbackReason)
			}
			if tc.ExpectFallbackReason != "" && res.FallbackReason != tc.ExpectFallbackReason {
				t.Fatalf("FallbackReason = %q, want %q", res.FallbackReason, tc.ExpectFallbackReason)
			}
			if tc.ExpectAnchors != nil {
				gotAnchors := make([]string, len(res.Anchors))
				for i, a := range res.Anchors {
					gotAnchors[i] = a.ID
					if a.BlockIndex < 0 || a.BlockIndex >= len(res.Blocks) {
						t.Fatalf("anchor %q has out-of-range blockIndex %d (blocks=%d)", a.ID, a.BlockIndex, len(res.Blocks))
					}
				}
				if !slices.Equal(gotAnchors, tc.ExpectAnchors) {
					t.Fatalf("anchors = %v, want %v", gotAnchors, tc.ExpectAnchors)
				}
			}
			if tc.ExpectBlockKinds != nil {
				gotKinds := make([]string, len(res.Blocks))
				for i, b := range res.Blocks {
					gotKinds[i] = b.Kind
				}
				if !slices.Equal(gotKinds, tc.ExpectBlockKinds) {
					t.Fatalf("block kinds = %v, want %v", gotKinds, tc.ExpectBlockKinds)
				}
			}
			if len(tc.ForbidSubstrings) > 0 {
				encoded, err := json.Marshal(res)
				if err != nil {
					t.Fatal(err)
				}
				for _, bad := range tc.ForbidSubstrings {
					if strings.Contains(string(encoded), bad) {
						t.Fatalf("response leaked forbidden substring %q: %s", bad, encoded)
					}
				}
			}
		})
	}

	for _, tc := range fixture.HoverDocs {
		t.Run("hoverDoc/"+tc.Name, func(t *testing.T) {
			res, err := c.RenderHoverDoc(ctx, []byte(tc.Contents), tc.IsMarkdown, tc.Language)
			if err != nil {
				t.Fatalf("RenderHoverDoc failed: %v", err)
			}
			if res.FallbackToSource != tc.ExpectFallback {
				t.Fatalf("FallbackToSource = %v, want %v (reason=%q)", res.FallbackToSource, tc.ExpectFallback, res.FallbackReason)
			}
			if tc.ExpectFallbackReason != "" && res.FallbackReason != tc.ExpectFallbackReason {
				t.Fatalf("FallbackReason = %q, want %q", res.FallbackReason, tc.ExpectFallbackReason)
			}
			if tc.ExpectBlockKinds != nil {
				gotKinds := make([]string, len(res.Blocks))
				for i, b := range res.Blocks {
					gotKinds[i] = b.Kind
				}
				if !slices.Equal(gotKinds, tc.ExpectBlockKinds) {
					t.Fatalf("block kinds = %v, want %v", gotKinds, tc.ExpectBlockKinds)
				}
			}
			if tc.ExpectFirstCodeText != "" {
				if len(res.Blocks) == 0 || res.Blocks[0].Kind != DocBlockCode || res.Blocks[0].Text != tc.ExpectFirstCodeText {
					t.Fatalf("first block = %+v, want code text %q", res.Blocks, tc.ExpectFirstCodeText)
				}
			}
			if len(tc.ExpectSubstrings) > 0 || len(tc.ForbidSubstrings) > 0 {
				encoded, err := json.Marshal(res)
				if err != nil {
					t.Fatal(err)
				}
				text := string(encoded)
				for _, want := range tc.ExpectSubstrings {
					if !strings.Contains(text, want) {
						t.Fatalf("response missing %q: %s", want, text)
					}
				}
				for _, bad := range tc.ForbidSubstrings {
					if strings.Contains(text, bad) {
						t.Fatalf("response leaked forbidden substring %q: %s", bad, text)
					}
				}
			}
		})
	}
}

func TestDocRenderDecodesRichIRFieldsAndRespectsCancellation(t *testing.T) {
	c := NewClient()
	fixture := loadDocRenderFixture(t)

	// Verify rich Javadoc fields (links, code, labeled tagKind, anchors) decode properly.
	first := fixture.DocComments[0]
	res, err := c.RenderDocComment(context.Background(), []byte(first.Source), first.ShellKind, first.Dialect, first.Language)
	if err != nil {
		t.Fatal(err)
	}
	foundSymbolLink := false
	foundTypeParam := false
	for _, block := range res.Blocks {
		if block.Kind == DocBlockLabeled && block.TagKind == "typeParam" {
			foundTypeParam = true
		}
		for _, span := range block.Spans {
			if span.Link != nil && span.Link.Kind == DocLinkSymbolRef && span.Link.Target == "#iterator()" {
				foundSymbolLink = true
			}
		}
	}
	if !foundSymbolLink || !foundTypeParam {
		t.Fatalf("missing decoded Javadoc structures: foundSymbolLink=%v foundTypeParam=%v blocks=%+v", foundSymbolLink, foundTypeParam, res.Blocks)
	}

	// Verify table cells decode properly.
	tableCase := fixture.DocComments[2]
	tableRes, err := c.RenderDocComment(context.Background(), []byte(tableCase.Source), tableCase.ShellKind, tableCase.Dialect, tableCase.Language)
	if err != nil {
		t.Fatal(err)
	}
	if len(tableRes.Blocks) != 1 || tableRes.Blocks[0].Kind != DocBlockTable || tableRes.Blocks[0].Columns != 2 || len(tableRes.Blocks[0].Rows) != 2 {
		t.Fatalf("unexpected table IR: %+v", tableRes.Blocks)
	}

	// Verify HTML <dl><dt>/<dd> rich LabelSpans decode cleanly.
	dlRes, err := c.RenderDocComment(context.Background(), []byte("/** <dl><dt><b>Key</b></dt><dd>Value</dd></dl> */"), "block-star", "javadoc-html", "java")
	if err != nil {
		t.Fatal(err)
	}
	if len(dlRes.Blocks) != 1 || dlRes.Blocks[0].Kind != DocBlockLabeled || len(dlRes.Blocks[0].LabelSpans) == 0 || dlRes.Blocks[0].LabelSpans[0].Text != "Key" || !dlRes.Blocks[0].LabelSpans[0].Bold {
		t.Fatalf("unexpected <dl> labeled IR: %+v", dlRes.Blocks)
	}

	// Verify empty slice and cancelled context handling.
	emptyRes, err := c.RenderHoverDoc(context.Background(), nil, false, "")
	if err != nil || len(emptyRes.Blocks) != 0 {
		t.Fatalf("empty hover = %+v, %v", emptyRes, err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := c.RenderDocComment(ctx, []byte("/** hi */"), "block-star", "javadoc-html", "java"); !errors.Is(err, context.Canceled) {
		t.Fatalf("cancelled RenderDocComment = %v, want context.Canceled", err)
	}
	if _, err := c.RenderHoverDoc(ctx, []byte("hi"), true, "java"); !errors.Is(err, context.Canceled) {
		t.Fatalf("cancelled RenderHoverDoc = %v, want context.Canceled", err)
	}
}
