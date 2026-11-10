package mcpconfig

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"time"
)

// RegistryBaseURL is the official MCP Registry v0.1 server list. Only an explicit search
// contacts it; the featured catalog is Core's compile-time data and needs no request.
const RegistryBaseURL = "https://registry.modelcontextprotocol.io/v0.1/servers"

const (
	registryTimeout   = 30 * time.Second
	registryPageLimit = 30
	// registryBodyLimit is Core's accepted size for mcp.parseRegistry.
	registryBodyLimit = 1 << 20
)

// ErrRegistryTooLarge reports a page over the size Core accepts.
var ErrRegistryTooLarge = errors.New("registry response is too large")

var registryClient = &http.Client{
	CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
}

// FetchRegistry asks the registry at base for one page of servers matching query, continuing
// from the opaque cursor, and returns the body for core mcp.parseRegistry. The request is
// cancellable through ctx, follows no redirect and keeps no cookies. It installs and runs
// nothing.
func FetchRegistry(ctx context.Context, base, query, cursor string) (string, error) {
	address, err := url.Parse(base)
	if err != nil || address.Scheme != "https" && address.Hostname() != "127.0.0.1" {
		return "", errors.New("registry address must be HTTPS")
	}
	values := address.Query()
	values.Set("limit", fmt.Sprint(registryPageLimit))
	if query != "" {
		values.Set("search", query)
	}
	if cursor != "" {
		values.Set("cursor", cursor)
	}
	address.RawQuery = values.Encode()
	ctx, cancel := context.WithTimeout(ctx, registryTimeout)
	defer cancel()
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, address.String(), nil)
	if err != nil {
		return "", err
	}
	request.Header.Set("Accept", "application/json")
	response, err := registryClient.Do(request)
	if err != nil {
		if ctx.Err() != nil {
			return "", ctx.Err()
		}
		// The transport error can echo the query; report the class only.
		return "", errors.New("registry request failed")
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return "", fmt.Errorf("registry answered HTTP %d", response.StatusCode)
	}
	data, err := io.ReadAll(io.LimitReader(response.Body, registryBodyLimit+1))
	if err != nil {
		return "", errors.New("registry response could not be read")
	}
	if len(data) > registryBodyLimit {
		return "", ErrRegistryTooLarge
	}
	return string(data), nil
}
