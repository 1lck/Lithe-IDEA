package marketplace

import (
	"context"
	"errors"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"
)

type iconBody struct {
	io.Reader
	closed bool
}

func (b *iconBody) Close() error { b.closed = true; return nil }

func TestFetchIconBoundsAndClosesTheResponse(t *testing.T) {
	const svg = `<svg viewBox="0 0 16 16"><path fill="#548AF7" d="M1 1H15V15H1Z"/></svg>`
	for _, scenario := range []struct {
		name   string
		status int
		length int64
		limit  int64
		want   string
	}{
		{"svg", 200, int64(len(svg)), int64(len(svg)), ""},
		{"declared too large", 200, int64(len(svg)), 16, "exceeds"},
		{"stream too large", 200, -1, 16, "exceeds"},
		{"missing", 404, 0, 256, "404"},
	} {
		t.Run(scenario.name, func(t *testing.T) {
			body := &iconBody{Reader: strings.NewReader(svg)}
			service := New(nil, &http.Client{Transport: transportFunc(func(r *http.Request) (*http.Response, error) {
				if r.URL.String() != "https://raw.githubusercontent.com/example/icons/main/brand.svg" || r.Header.Get("Accept") != "image/svg+xml" {
					t.Errorf("unexpected icon request: %s %s", r.URL, r.Header.Get("Accept"))
				}
				return &http.Response{StatusCode: scenario.status, ContentLength: scenario.length, Body: body, Request: r}, nil
			})})
			ctx, cancel := context.WithTimeout(context.Background(), time.Second)
			defer cancel()
			data, err := service.FetchIcon(ctx, "https://raw.githubusercontent.com/example/icons/main/brand.svg", scenario.limit)
			if !body.closed {
				t.Fatal("the response body was left open")
			}
			if scenario.want == "" {
				if err != nil || string(data) != svg {
					t.Fatalf("icon = %q, error = %v", data, err)
				}
			} else if err == nil || !strings.Contains(err.Error(), scenario.want) {
				t.Fatalf("error = %v, want %q", err, scenario.want)
			}
		})
	}
}

func TestFetchIconCancellationAndRedirectPolicy(t *testing.T) {
	t.Run("cancel", func(t *testing.T) {
		started, stopped := make(chan struct{}), make(chan struct{})
		service := New(nil, &http.Client{Transport: transportFunc(func(r *http.Request) (*http.Response, error) {
			close(started)
			<-r.Context().Done()
			return nil, r.Context().Err()
		})})
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		var result error
		go func() {
			defer close(stopped)
			_, result = service.FetchIcon(ctx, "https://raw.githubusercontent.com/example/icons/main/brand.svg", 256)
		}()
		t.Cleanup(func() {
			cancel()
			select {
			case <-stopped:
			case <-time.After(2 * time.Second):
				t.Error("cancelled icon fetch did not stop")
			}
		})
		select {
		case <-started:
		case <-ctx.Done():
			t.Fatal("icon fetch did not start")
		}
		cancel()
		select {
		case <-stopped:
		case <-time.After(2 * time.Second):
			t.Fatal("icon fetch ignored cancellation")
		}
		if !errors.Is(result, context.Canceled) {
			t.Fatalf("fetch error = %v", result)
		}
	})
	t.Run("redirect", func(t *testing.T) {
		service := New(nil, &http.Client{Transport: transportFunc(func(r *http.Request) (*http.Response, error) {
			return &http.Response{StatusCode: 302, Header: http.Header{"Location": {"http://example.com/icon.svg"}}, Body: io.NopCloser(strings.NewReader("")), Request: r}, nil
		})})
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		_, err := service.FetchIcon(ctx, "https://raw.githubusercontent.com/example/icons/main/brand.svg", 256)
		if !errors.Is(err, ErrUnsafeRedirect) {
			t.Fatalf("unsafe icon redirect = %v", err)
		}
	})
}
