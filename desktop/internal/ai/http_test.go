package ai

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestHeadersFollowTheProviderAuthentication(t *testing.T) {
	h := headers("anthropicMessages", "apiKey", "secret")
	if h["x-api-key"] != "secret" || h["anthropic-version"] == "" || h["Authorization"] != "" {
		t.Fatalf("headers = %v", h)
	}
	h = headers("responses", "bearer", "secret")
	if h["Authorization"] != "Bearer secret" {
		t.Fatalf("headers = %v", h)
	}
}

func TestPostBoundsTheAnswer(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/big":
			_, _ = io.WriteString(w, strings.Repeat("x", responseLimit+1))
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
	ctx := testContext(t)
	auth := map[string]string{"Authorization": "Bearer k"}
	if data, err := post(ctx, server.URL+"/ok", auth, []byte(`{}`)); err != nil || string(data) != `{"ok":true}` {
		t.Fatalf("ok = %q %v", data, err)
	}
	if _, err := post(ctx, server.URL+"/big", auth, nil); !errors.Is(err, ErrResponseTooLarge) {
		t.Fatalf("big = %v", err)
	}
	var status *HTTPError
	if _, err := post(ctx, server.URL+"/redirect", auth, nil); !errors.As(err, &status) || status.Status != http.StatusFound {
		t.Fatalf("redirect was followed or hidden: %v", err)
	}
	if _, err := post(ctx, server.URL+"/error", auth, nil); !errors.As(err, &status) || strings.Contains(err.Error(), "secret") {
		t.Fatalf("error = %v", err)
	}
	cancelled, cancel := context.WithCancel(ctx)
	cancel()
	if _, err := post(cancelled, server.URL+"/ok", auth, nil); !errors.Is(err, context.Canceled) {
		t.Fatalf("cancelled = %v", err)
	}
}

// The plan Core makes for a staged diff is sent to the provider with the credential attached
// by this package only, and the answer decodes to the message.
func TestCommitRoundTripThroughCore(t *testing.T) {
	var gotAuth, gotBody string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAuth = r.Header.Get("Authorization")
		data, _ := io.ReadAll(r.Body)
		gotBody = string(data)
		_, _ = io.WriteString(w, `{"choices":[{"message":{"content":"feat: add thing"}}]}`)
	}))
	defer server.Close()
	client := testClient()
	ctx := testContext(t)
	n := len("+x")
	plan, err := client.PlanCommit(ctx, PlanProvider{
		ID: "codex", Name: "t", Endpoint: server.URL, Model: "m", APIProtocol: "chatCompletions",
		Authentication: "bearer", Source: "codex", RequiresAPIKey: true, AllowsInsecureHTTP: true,
	}, NewCommitOptions("english", false, ""), []EvidenceFile{{Path: "a.go", ChangeKind: "added", Diff: "+x", OriginalCharacters: &n}})
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(plan.Body), "Bearer") {
		t.Fatal("the plan carries a credential")
	}
	answer, err := post(ctx, plan.URL, headers("chatCompletions", "bearer", "k"), plan.Body)
	if err != nil {
		t.Fatal(err)
	}
	message, err := client.DecodeCommitMessage(ctx, "chatCompletions", json.RawMessage(answer), false)
	if err != nil || message != "feat: add thing" || gotAuth != "Bearer k" || !strings.Contains(gotBody, "a.go") {
		t.Fatalf("message=%q err=%v auth=%q", message, err, gotAuth)
	}
}
