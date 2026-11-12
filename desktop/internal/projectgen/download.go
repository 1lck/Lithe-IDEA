package projectgen

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
)

// maxArchiveBytes bounds one download. Core bounds the extracted size again.
const maxArchiveBytes = 512 << 20

// errInsecureURL reports an archive address that is neither HTTPS nor a loopback HTTP server.
var errInsecureURL = errors.New("projectgen: the archive address must use HTTPS")

// allowedURL accepts HTTPS, and HTTP only for loopback hosts, as the contract does.
func allowedURL(address *url.URL) bool {
	if address.User != nil || address.Host == "" {
		return false
	}
	if address.Scheme == "https" {
		return true
	}
	if address.Scheme != "http" {
		return false
	}
	host := address.Hostname()
	if host == "localhost" {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

// download saves the body of address into destination. A redirect must keep the
// same rules, and the byte count is bounded however large the headers claim.
func download(ctx context.Context, client *http.Client, address, destination string) error {
	parsed, err := url.Parse(address)
	if err != nil || !allowedURL(parsed) {
		return errInsecureURL
	}
	if client == nil {
		client = &http.Client{}
	}
	limited := *client
	limited.CheckRedirect = func(request *http.Request, via []*http.Request) error {
		if len(via) >= 5 {
			return errors.New("projectgen: too many redirects")
		}
		if !allowedURL(request.URL) {
			return errInsecureURL
		}
		return nil
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, address, nil)
	if err != nil {
		return err
	}
	request.Header.Set("User-Agent", "Lithe-IDE project generator")
	response, err := limited.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return fmt.Errorf("projectgen: the server answered %s", response.Status)
	}
	file, err := os.OpenFile(destination, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return err
	}
	written, copyErr := io.Copy(file, io.LimitReader(response.Body, maxArchiveBytes+1))
	closeErr := file.Close()
	if copyErr != nil {
		return copyErr
	}
	if written > maxArchiveBytes {
		return errors.New("projectgen: the archive is larger than the limit")
	}
	return closeErr
}
