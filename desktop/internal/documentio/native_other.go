//go:build !darwin && !windows && !linux

package documentio

import "os"

// Unsupported platforms fail before any replacement until their native metadata and
// atomic-replace behavior have been verified.
func openDocument(string) (*os.File, os.FileInfo, fileIdentity, error) {
	return nil, nil, fileIdentity{}, ErrUnsupported
}
func copyMetadata(*os.File, *os.File, os.FileInfo) error { return ErrUnsupported }
func replaceDocument(string, string) error               { return ErrUnsupported }
func installMissingDocument(string, string) error        { return ErrUnsupported }
