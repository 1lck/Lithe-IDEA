package marketplace

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
)

// FetchIcon reads an icon URL from a Core-validated marketplace entry. The
// rendering adapter supplies its byte limit and decodes the result off the UI
// thread. The service keeps no disk cache and uses the index's HTTPS redirect
// policy; a page cancellation interrupts the request and closes its body.
func (s *Service) FetchIcon(ctx context.Context, address string, maxBytes int64) (data []byte, err error) {
	if maxBytes <= 0 {
		return nil, fmt.Errorf("marketplace icon requires a positive read limit")
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, address, nil)
	if err != nil {
		return nil, err
	}
	request.Header.Set("Accept", "image/svg+xml")
	response, err := s.http.Do(request)
	if err != nil {
		return nil, err
	}
	defer func() {
		if closeErr := response.Body.Close(); closeErr != nil {
			err = errors.Join(err, closeErr)
		}
	}()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return nil, httpStatusError(response.StatusCode)
	}
	if response.ContentLength > maxBytes {
		return nil, fmt.Errorf("marketplace icon exceeds %d bytes", maxBytes)
	}
	data, err = io.ReadAll(io.LimitReader(response.Body, maxBytes+1))
	if err != nil {
		return nil, err
	}
	if int64(len(data)) > maxBytes {
		return nil, fmt.Errorf("marketplace icon exceeds %d bytes", maxBytes)
	}
	return data, nil
}
