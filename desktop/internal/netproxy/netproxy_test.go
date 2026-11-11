package netproxy

import (
	"context"
	"encoding/base64"
	"net"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// proxyServer is a local HTTP proxy that answers every request it carries itself, and records
// the hosts it was asked for and the credentials it was handed.
type proxyServer struct {
	server *httptest.Server
	mu     sync.Mutex
	hosts  []string
	auth   []string
	status int
}

func newProxyServer(t *testing.T, status int) *proxyServer {
	t.Helper()
	p := &proxyServer{status: status}
	p.server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		p.mu.Lock()
		p.hosts = append(p.hosts, r.Host)
		p.auth = append(p.auth, r.Header.Get("Proxy-Authorization"))
		p.mu.Unlock()
		if p.status/100 == 3 {
			w.Header().Set("Location", "http://elsewhere.invalid/")
		}
		w.WriteHeader(p.status)
	}))
	t.Cleanup(p.server.Close)
	return p
}

// policy is a custom policy naming the proxy.
func (p *proxyServer) policy(t *testing.T) core.NetworkProxyPolicy {
	t.Helper()
	host, port, err := net.SplitHostPort(p.server.Listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	number, _ := strconv.Atoi(port)
	return core.NetworkProxyPolicy{Policy: "custom", ProxyType: "http", Host: host, Port: number, Configured: true}
}

func (p *proxyServer) seen() ([]string, []string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	return append([]string(nil), p.hosts...), append([]string(nil), p.auth...)
}

func checkContext(t *testing.T) context.Context {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	t.Cleanup(cancel)
	return ctx
}

// TestCheckSendsOneRequestThroughTheProxyWithItsAccount checks the connection check: the request
// goes through the policy's server with the account's credentials, a redirect is the answer and
// is not followed, and the policy in force is left alone.
func TestCheckSendsOneRequestThroughTheProxyWithItsAccount(t *testing.T) {
	proxy := newProxyServer(t, http.StatusFound)
	policy := proxy.policy(t)
	policy.Username, policy.Password = "ada", "secret"

	status, elapsed, err := Check(checkContext(t), policy, "http://lithe-check.invalid/")
	if err != nil || status != http.StatusFound || elapsed <= 0 {
		t.Fatalf("check = %d after %v, %v", status, elapsed, err)
	}
	hosts, auth := proxy.seen()
	want := "Basic " + base64.StdEncoding.EncodeToString([]byte("ada:secret"))
	if len(hosts) != 1 || hosts[0] != "lithe-check.invalid" || auth[0] != want {
		t.Fatalf("the proxy carried %q with credentials %q", hosts, auth)
	}
	if current.Load() != nil {
		t.Fatal("the check replaced the policy in force")
	}
}

// TestCheckGoesDirectToAnExcludedHostAndReportsTheCause checks that the check follows the
// policy's exclusions, as the application's requests do, and that a failure is the cause alone,
// without the request it was for.
func TestCheckGoesDirectToAnExcludedHostAndReportsTheCause(t *testing.T) {
	proxy := newProxyServer(t, http.StatusNoContent)
	direct := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusOK) }))
	t.Cleanup(direct.Close)
	policy := proxy.policy(t)
	policy.Exclusions = []string{"127.0.0.1"}

	if status, _, err := Check(checkContext(t), policy, direct.URL); err != nil || status != http.StatusOK {
		t.Fatalf("the excluded host = %d, %v", status, err)
	}
	if hosts, _ := proxy.seen(); len(hosts) != 0 {
		t.Fatalf("the proxy carried a request for an excluded host: %q", hosts)
	}

	proxy.server.Close()
	_, _, err := Check(checkContext(t), proxy.policy(t), "http://lithe-check.invalid/")
	if err == nil || strings.Contains(err.Error(), "lithe-check.invalid") {
		t.Fatalf("a closed proxy = %v, want the cause without the request", err)
	}
}
