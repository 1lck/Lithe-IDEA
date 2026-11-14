package ai

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net/http"
	"time"
)

// Provider requests are made here, by the platform: Core only plans the request and decodes
// the answer. The limits follow Lithe-core-rust rust/contracts/ai-commit.md: a 45-second
// deadline, no redirects, no cookies, and a 2 MiB cap on the answer.
const (
	// RequestTimeout bounds one provider request.
	RequestTimeout = 45 * time.Second
	responseLimit  = 2 << 20
)

var (
	// ErrResponseTooLarge reports an answer over 2 MiB.
	ErrResponseTooLarge = errors.New("ai response too large")
	// ErrTimeout reports a provider that did not answer within RequestTimeout.
	ErrTimeout = errors.New("ai request timed out")
	// errNetwork is a transport failure. The transport error can contain the URL, so only the
	// class is reported.
	errNetwork = errors.New("AI_NETWORK_ERROR")
)

// HTTPError is a provider answer that was not a success. It carries the status only: the body
// can echo the request, which holds the user's code.
type HTTPError struct{ Status int }

func (e *HTTPError) Error() string { return "AI_HTTP_" + http.StatusText(e.Status) }

// httpClient never follows a redirect and keeps no cookies, so a credential cannot be forwarded
// to another host.
var httpClient = &http.Client{
	CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
}

// headers are the authentication headers of one commit or pull request provider request. The
// credential is attached here and nowhere else; it is never logged or returned.
func headers(protocol, authentication, key string) map[string]string {
	out := map[string]string{"Content-Type": "application/json"}
	switch {
	case authentication == "apiKey":
		out["x-api-key"] = key
	default:
		out["Authorization"] = "Bearer " + key
	}
	if protocol == "anthropicMessages" {
		out["anthropic-version"] = "2023-06-01"
	}
	return out
}

// post sends body to url and returns the answer, bounded to 2 MiB.
func post(ctx context.Context, url string, headers map[string]string, body []byte) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, RequestTimeout)
	defer cancel()
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	for name, value := range headers {
		request.Header.Set(name, value)
	}
	response, err := httpClient.Do(request)
	if err != nil {
		if errors.Is(ctx.Err(), context.DeadlineExceeded) {
			return nil, ErrTimeout
		}
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		return nil, errNetwork
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode > 299 {
		return nil, &HTTPError{Status: response.StatusCode}
	}
	data, err := io.ReadAll(io.LimitReader(response.Body, responseLimit+1))
	if err != nil {
		if errors.Is(ctx.Err(), context.DeadlineExceeded) {
			return nil, ErrTimeout
		}
		return nil, errNetwork
	}
	if len(data) > responseLimit {
		return nil, ErrResponseTooLarge
	}
	return data, nil
}
