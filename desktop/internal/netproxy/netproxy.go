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
	"context"
	"errors"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

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
	return proxyFor(current.Load(), request)
}

// proxyFor is the proxy for request under policy; a nil policy is the system's.
func proxyFor(policy *core.NetworkProxyPolicy, request *http.Request) (*url.URL, error) {
	if policy == nil || policy.Policy == "system" || policy.Policy == "" {
		return http.ProxyFromEnvironment(request)
	}
	if policy.Policy == "direct" || request.URL == nil {
		return nil, nil
	}
	if Bypasses(request.URL.Hostname(), policy.ExclusionRules) {
		return nil, nil
	}
	return proxyURL(*policy), nil
}

// Check sends one HEAD request for target under policy, on a transport of its own, so the check
// neither uses nor closes the connections of the policy in force. A redirect is not followed:
// any answer shows that the proxy carried the request. It returns the answer's status and the
// time it took, or why no answer came; ctx bounds the wait.
func Check(ctx context.Context, policy core.NetworkProxyPolicy, target string) (int, time.Duration, error) {
	transport := &http.Transport{}
	if base, ok := http.DefaultTransport.(*http.Transport); ok {
		transport = base.Clone()
	}
	transport.Proxy = func(request *http.Request) (*url.URL, error) { return proxyFor(&policy, request) }
	defer transport.CloseIdleConnections()
	client := &http.Client{
		Transport:     transport,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodHead, target, nil)
	if err != nil {
		return 0, 0, err
	}
	started := time.Now()
	response, err := client.Do(request)
	elapsed := time.Since(started)
	if err != nil {
		// The request's own address is known to the caller; the cause is what it needs.
		var failure *url.Error
		if errors.As(err, &failure) {
			err = failure.Err
		}
		return 0, elapsed, err
	}
	_ = response.Body.Close()
	return response.StatusCode, elapsed, nil
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

// Bypasses reports whether host, a request URL's host name or address, goes direct under
// rules. Core reads what each exclusion entry means (network.proxyPolicy); this is only the
// comparison its contract states, replayed against rust/fixtures/network/proxy-bypass-v1.json:
// the host lowercase and without a trailing dot; "host" equal; "suffix" the domain or a host
// ending in "." and the domain; "ip" an equal address and "cidr" an address inside the block,
// both of the same family, an IPv6 zone not compared; "local" a name without a dot.
func Bypasses(host string, rules []core.NetworkProxyExclusionRule) bool {
	host = strings.ToLower(strings.TrimSuffix(host, "."))
	if host == "" {
		return false
	}
	address, err := netip.ParseAddr(host)
	isAddress := err == nil
	address = address.WithZone("")
	for _, rule := range rules {
		switch rule.Kind {
		case "host":
			if host == rule.Value {
				return true
			}
		case "suffix":
			if host == rule.Value || strings.HasSuffix(host, "."+rule.Value) {
				return true
			}
		case "ip":
			if value, err := netip.ParseAddr(rule.Value); err == nil && isAddress && address == value {
				return true
			}
		case "cidr":
			if block, err := netip.ParsePrefix(rule.Value); err == nil && isAddress && block.Contains(address) {
				return true
			}
		case "local":
			if !isAddress && !strings.Contains(host, ".") {
				return true
			}
		}
	}
	return false
}
