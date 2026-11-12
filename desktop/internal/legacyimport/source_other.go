//go:build !darwin && !windows

package legacyimport

import "context"

// macDomain names the macOS source; unused here but shared by the mapping.
const macDomain = "app.lithe.desktop"

// read finds nothing: no earlier Lithe client ran on this platform.
func read(context.Context) (Found, error) { return Found{}, ErrNotFound }
