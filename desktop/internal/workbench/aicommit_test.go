package workbench

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

func TestStagedChangeKindUsesTheIndexSide(t *testing.T) {
	for status, want := range map[string]string{"A ": "added", "M ": "modified", "MM": "modified", "D ": "deleted", "R ": "renamed", "C ": "copied", "UU": "unmerged", "": "modified"} {
		if got := stagedChangeKind(status); got != want {
			t.Errorf("%q = %q, want %q", status, got, want)
		}
	}
}

func TestPickAIProviderNeedsACredential(t *testing.T) {
	providers := map[string][]agentProvider{
		"codex":  {{Endpoint: "https://a", MissingKey: true}},
		"claude": {{Endpoint: "https://b", APIKey: "k", Issue: ""}},
	}
	got, ok := pickAIProvider(providers)
	if !ok || got.Endpoint != "https://b" {
		t.Fatalf("picked %#v %v", got, ok)
	}
	if _, ok := pickAIProvider(map[string][]agentProvider{"codex": {{Endpoint: "https://a", APIKey: "k", Issue: agentIssueCredential}}}); ok {
		t.Fatal("a provider with an issue was picked")
	}
}

func TestAIHeadersFollowTheProviderAuthentication(t *testing.T) {
	h := aiHeaders("anthropicMessages", "apiKey", "secret")
	if h["x-api-key"] != "secret" || h["anthropic-version"] == "" || h["Authorization"] != "" {
		t.Fatalf("headers = %v", h)
	}
	h = aiHeaders("responses", "bearer", "secret")
	if h["Authorization"] != "Bearer secret" {
		t.Fatalf("headers = %v", h)
	}
}

func TestAIPostBoundsTheAnswer(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/big":
			_, _ = io.WriteString(w, strings.Repeat("x", aiResponseLimit+1))
		case "/redirect":
			http.Redirect(w, r, "/ok", http.StatusFound)
		case "/error":
			http.Error(w, "echoed secret body", http.StatusUnauthorized)
		default:
			if r.Header.Get("Authorization") != "Bearer k" {
				http.Error(w, "no", http.StatusForbidden)
				return
			}
			_, _ = io.WriteString(w, `{"ok":true}`)
		}
	}))
	defer server.Close()
	ctx := context.Background()
	headers := map[string]string{"Authorization": "Bearer k"}
	if data, err := aiPost(ctx, server.URL+"/ok", headers, []byte(`{}`)); err != nil || string(data) != `{"ok":true}` {
		t.Fatalf("ok = %q %v", data, err)
	}
	if _, err := aiPost(ctx, server.URL+"/big", headers, nil); !errors.Is(err, errAIResponseTooLarge) {
		t.Fatalf("big = %v", err)
	}
	var status *aiHTTPError
	if _, err := aiPost(ctx, server.URL+"/redirect", headers, nil); !errors.As(err, &status) || status.Status != http.StatusFound {
		t.Fatalf("redirect was followed or hidden: %v", err)
	}
	if _, err := aiPost(ctx, server.URL+"/error", headers, nil); !errors.As(err, &status) || strings.Contains(err.Error(), "secret") {
		t.Fatalf("error = %v", err)
	}
	cancelled, cancel := context.WithCancel(ctx)
	cancel()
	if _, err := aiPost(cancelled, server.URL+"/ok", headers, nil); !errors.Is(err, context.Canceled) {
		t.Fatalf("cancelled = %v", err)
	}
}

// The plan Core makes for a staged diff is sent to the provider with the credential attached
// by this package only, and the answer decodes to the message.
func TestCommitGenerationRoundTripThroughCore(t *testing.T) {
	var gotAuth, gotBody string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAuth = r.Header.Get("Authorization")
		data, _ := io.ReadAll(r.Body)
		gotBody = string(data)
		_, _ = io.WriteString(w, `{"choices":[{"message":{"content":"feat: add thing"}}]}`)
	}))
	defer server.Close()
	client := core.NewClient()
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	n := len("+x")
	plan, err := client.AIPlanCommit(ctx, core.AICommitProvider{
		ID: "codex", Name: "t", Endpoint: server.URL, Model: "m", APIProtocol: "chatCompletions",
		Authentication: "bearer", Source: "codex", RequiresAPIKey: true, AllowsInsecureHTTP: true,
	}, core.AICommitOptions{Language: "english", Format: "conventional", SubjectMaximumLength: 72, MaximumDiffCharacters: 32000, ReasoningEffort: "default"},
		[]core.AICommitFile{{Path: "a.go", ChangeKind: "added", Diff: "+x", OriginalCharacters: &n}})
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(plan.Body), "Bearer") {
		t.Fatal("the plan carries a credential")
	}
	answer, err := aiPost(ctx, plan.URL, aiHeaders("chatCompletions", "bearer", "k"), plan.Body)
	if err != nil {
		t.Fatal(err)
	}
	message, err := client.AIDecodeCommitMessage(ctx, "chatCompletions", json.RawMessage(answer), false)
	if err != nil || message != "feat: add thing" || gotAuth != "Bearer k" || !strings.Contains(gotBody, "a.go") {
		t.Fatalf("message=%q err=%v auth=%q", message, err, gotAuth)
	}
}
