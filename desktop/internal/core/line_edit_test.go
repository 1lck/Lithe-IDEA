package core

import (
	"context"
	"encoding/json"
	"os"
	"reflect"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/contractfixture"
)

func TestLineEditsUseCoreFixtures(t *testing.T) {
	data, err := os.ReadFile(contractfixture.CoreFixture("editor/line-edit-v1.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Cases []struct {
			Name     string          `json:"name"`
			Request  json.RawMessage `json:"request"`
			Expected json.RawMessage `json:"expected"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	client := NewClient()
	for _, item := range fixture.Cases {
		t.Run(item.Name, func(t *testing.T) {
			var kind struct {
				Identifier *string `json:"identifier"`
			}
			if err := json.Unmarshal(item.Request, &kind); err != nil {
				t.Fatal(err)
			}
			if kind.Identifier != nil {
				var expected struct {
					Token *string `json:"token"`
				}
				if err := json.Unmarshal(item.Expected, &expected); err != nil {
					t.Fatal(err)
				}
				result, err := client.LineCommentToken(testContext(t), *kind.Identifier)
				if err != nil || !reflect.DeepEqual(result, expected.Token) {
					t.Fatalf("token = %v, error = %v; want %v", result, err, expected.Token)
				}
				return
			}
			var request LineEditRequest
			var expected LineEditOutcome
			if err := json.Unmarshal(item.Request, &request); err != nil {
				t.Fatal(err)
			}
			if err := json.Unmarshal(item.Expected, &expected); err != nil {
				t.Fatal(err)
			}
			result, err := client.LineEdit(testContext(t), request)
			if err != nil || !reflect.DeepEqual(result, expected) {
				t.Fatalf("result = %#v, error = %v; want %#v", result, err, expected)
			}
		})
	}
}

func TestLineCommentTokenUsesCoreLanguageTable(t *testing.T) {
	client, ctx := NewClient(), testContext(t)
	token, err := client.LineCommentToken(ctx, "example.go")
	if err != nil || token == nil || *token != "//" {
		t.Fatalf("Go token = %v, error = %v", token, err)
	}
	token, err = client.LineCommentToken(ctx, "unknown.fixture-extension")
	if err != nil || token != nil {
		t.Fatalf("unknown token = %v, error = %v", token, err)
	}
}

func BenchmarkCoreToggleLineComment(b *testing.B) {
	for _, size := range []struct {
		name  string
		lines int
	}{
		{name: "100KiB", lines: 9_310},
		{name: "1MiB", lines: 95_326},
		{name: "8MiB", lines: 762_600},
	} {
		b.Run(size.name, func(b *testing.B) {
			token := "//"
			request := LineEditRequest{Operation: ToggleLineComment, Source: strings.Repeat("0123456789\n", size.lines), CommentToken: &token}
			client := NewClient()
			b.ReportAllocs()
			b.SetBytes(int64(len(request.Source)))
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				if _, err := client.LineEdit(context.Background(), request); err != nil {
					b.Fatal(err)
				}
			}
		})
	}
}
