package workbench

import (
	"context"
	"encoding/base64"
	"net"
	"net/http"
	"net/http/httptest"
	"strconv"
	"sync"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/settingswindow"
)

// savedSecret is a secret store holding the saved proxy password.
type savedSecret string

func (s savedSecret) Get(_ context.Context, namespace, key string) (string, bool, error) {
	if namespace != networkCredentialNamespace || key != networkCredentialKey || s == "" {
		return "", false, nil
	}
	return string(s), true, nil
}

// TestNetworkCheckSendsTheDraftsAccountOnlyToItsEndpoint checks the Network page's connection
// check against Core's reading of the draft: a typed password goes with the draft, the saved
// one only while the draft still names the endpoint it was saved for, a cleared one not at all
// (the account still goes, with an empty password), and a draft without a server sends nothing.
func TestNetworkCheckSendsTheDraftsAccountOnlyToItsEndpoint(t *testing.T) {
	var mu sync.Mutex
	var auth []string
	proxy := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		auth = append(auth, r.Header.Get("Proxy-Authorization"))
		mu.Unlock()
		w.WriteHeader(http.StatusNoContent)
	}))
	t.Cleanup(proxy.Close)
	host, portText, err := net.SplitHostPort(proxy.Listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	port, _ := strconv.Atoi(portText)
	kernel := core.NewClient()
	draft := settingswindow.NetworkSettings{Mode: "custom", Host: host, Port: port, Username: "ada"}
	basic := func(password string) string {
		return "Basic " + base64.StdEncoding.EncodeToString([]byte("ada:"+password))
	}
	check := func(what string, draft settingswindow.NetworkSettings, saved savedSecret, password *string, want string) {
		t.Helper()
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		mu.Lock()
		auth = nil
		mu.Unlock()
		outcome := checkNetwork(ctx, kernel, saved, "http://lithe-check.invalid/", draft, password)
		if outcome.Err != nil || outcome.Incomplete || outcome.Status != http.StatusNoContent {
			t.Fatalf("%s: outcome %+v", what, outcome)
		}
		mu.Lock()
		defer mu.Unlock()
		if len(auth) != 1 || auth[0] != want {
			t.Fatalf("%s: the proxy was handed %q, want %q", what, auth, want)
		}
	}

	typed := "typed"
	check("a typed password", draft, "", &typed, basic("typed"))

	saved := draft
	saved.HasPassword = true
	saved.PasswordIdentity = &core.NetworkProxyIdentity{ProxyType: "http", Host: host, Port: port, Username: "ada"}
	check("the saved password of this endpoint", saved, "stored", nil, basic("stored"))

	moved := saved
	moved.PasswordIdentity = &core.NetworkProxyIdentity{ProxyType: "http", Host: "proxy.example.com", Port: port, Username: "ada"}
	check("the saved password of another endpoint", moved, "stored", nil, basic(""))

	cleared := ""
	check("a cleared password", saved, "stored", &cleared, basic(""))

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	empty := draft
	empty.Host = ""
	mu.Lock()
	auth = nil
	mu.Unlock()
	if outcome := checkNetwork(ctx, kernel, savedSecret(""), "http://lithe-check.invalid/", empty, nil); !outcome.Incomplete {
		t.Fatalf("a draft without a server = %+v", outcome)
	}
	mu.Lock()
	defer mu.Unlock()
	if len(auth) != 0 {
		t.Fatal("a draft without a server sent a request")
	}
}
