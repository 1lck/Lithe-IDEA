package workbench

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net/http"
	"time"
)

// AI provider requests are made here, by the platform: Core only plans the request and
// decodes the answer. The limits follow shared/contracts/ai-commit.md: a 45-second
// deadline, no redirects, no cookies, and a 2 MiB cap on the answer.
const (
	aiRequestTimeout = 45 * time.Second
	aiResponseLimit  = 2 << 20
)

var (
	errAIResponseTooLarge = errors.New("ai response too large")
	errAITimeout          = errors.New("ai request timed out")
)

// aiHTTPError is a provider answer that was not a success. It carries the status only:
// the body can echo the request, which holds the user's code.
type aiHTTPError struct{ Status int }

func (e *aiHTTPError) Error() string { return "AI_HTTP_" + http.StatusText(e.Status) }

// aiHTTPClient never follows a redirect and keeps no cookies, so a credential cannot be
// forwarded to another host.
var aiHTTPClient = &http.Client{
	CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
}

// aiHeaders are the authentication headers of one provider request. The credential is
// attached here and nowhere else; it is never logged or returned.
func aiHeaders(protocol, authentication, key string) map[string]string {
	headers := map[string]string{"Content-Type": "application/json"}
	switch {
	case authentication == "apiKey":
		headers["x-api-key"] = key
	default:
		headers["Authorization"] = "Bearer " + key
	}
	if protocol == "anthropicMessages" {
		headers["anthropic-version"] = "2023-06-01"
	}
	return headers
}

// aiPost sends body to url and returns the answer, bounded to 2 MiB.
func aiPost(ctx context.Context, url string, headers map[string]string, body []byte) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, aiRequestTimeout)
	defer cancel()
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	for name, value := range headers {
		request.Header.Set(name, value)
	}
	response, err := aiHTTPClient.Do(request)
	if err != nil {
		if errors.Is(ctx.Err(), context.DeadlineExceeded) {
			return nil, errAITimeout
		}
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		// The transport error can contain the URL; the caller reports the class only.
		return nil, errors.New("AI_NETWORK_ERROR")
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode > 299 {
		return nil, &aiHTTPError{Status: response.StatusCode}
	}
	data, err := io.ReadAll(io.LimitReader(response.Body, aiResponseLimit+1))
	if err != nil {
		if errors.Is(ctx.Err(), context.DeadlineExceeded) {
			return nil, errAITimeout
		}
		return nil, errors.New("AI_NETWORK_ERROR")
	}
	if len(data) > aiResponseLimit {
		return nil, errAIResponseTooLarge
	}
	return data, nil
}
