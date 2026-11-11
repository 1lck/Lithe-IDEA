// Package netproxy applies the user's proxy settings to the application's own HTTP
// traffic. Core normalizes the settings (network.proxyPolicy); this package keeps the
// resulting policy and answers, per request, which proxy a request goes through.
//
// Install points http.DefaultTransport at the current policy, so every client of the
// application that keeps Go's default transport follows the settings without being
// handed a client: the marketplace, plugin and project downloads, the MCP registry and
// the AI providers.
package netproxy

import (
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

var (
	current atomic.Pointer[core.NetworkProxyPolicy]
	once    sync.Once
)

// Install makes http.DefaultTransport ask the current policy for each request's proxy.
// Until Set is called the policy is the system's. It is safe to call more than once.
func Install() {
	once.Do(func() {
		if transport, ok := http.DefaultTransport.(*http.Transport); ok {
			transport.Proxy = Proxy
		}
	})
}

// Set replaces the policy requests use from now on. Connections already open to a
// proxy are closed, so no request keeps using a proxy the user switched away from.
func Set(policy core.NetworkProxyPolicy) {
	copied := policy
	current.Store(&copied)
	if transport, ok := http.DefaultTransport.(*http.Transport); ok {
		transport.CloseIdleConnections()
	}
}

// Proxy is the proxy for request under the current policy: the environment's
// (HTTP_PROXY, HTTPS_PROXY, NO_PROXY) for the system policy, none for the direct
// policy and for an excluded host, and the custom server otherwise.
func Proxy(request *http.Request) (*url.URL, error) {
	policy := current.Load()
	if policy == nil || policy.Policy == "system" || policy.Policy == "" {
		return http.ProxyFromEnvironment(request)
	}
	if policy.Policy == "direct" || request.URL == nil {
		return nil, nil
	}
	if Excluded(request.URL.Hostname(), policy.Exclusions) {
		return nil, nil
	}
	return proxyURL(*policy), nil
}

// proxyURL is the custom server as a URL the transport understands.
func proxyURL(policy core.NetworkProxyPolicy) *url.URL {
	scheme := "http"
	if policy.ProxyType == "socks5" {
		scheme = "socks5"
	}
	out := &url.URL{Scheme: scheme, Host: net.JoinHostPort(policy.Host, strconv.Itoa(policy.Port))}
	if policy.Username != "" {
		if policy.Password != "" {
			out.User = url.UserPassword(policy.Username, policy.Password)
		} else {
			out.User = url.User(policy.Username)
		}
	}
	return out
}

// Excluded reports whether host is reached directly under exclusions: an entry is an
// exact host, a domain suffix written ".example.com" or "*.example.com", an IP
// address, a CIDR block, or "<local>" for names without a dot.
func Excluded(host string, exclusions []string) bool {
	host = strings.ToLower(strings.TrimSuffix(host, "."))
	if host == "" {
		return false
	}
	ip := net.ParseIP(host)
	for _, entry := range exclusions {
		entry = strings.ToLower(strings.TrimSpace(entry))
		switch {
		case entry == "":
		case entry == "<local>":
			if ip == nil && !strings.Contains(host, ".") {
				return true
			}
		case strings.Contains(entry, "/"):
			if _, block, err := net.ParseCIDR(entry); err == nil && ip != nil && block.Contains(ip) {
				return true
			}
		case strings.HasPrefix(entry, "*."), strings.HasPrefix(entry, "."):
			suffix := strings.TrimPrefix(entry, "*")
			if strings.HasSuffix(host, suffix) || host == suffix[1:] {
				return true
			}
		default:
			if host == entry {
				return true
			}
		}
	}
	return false
}
