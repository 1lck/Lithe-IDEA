//go:build !windows || (!amd64 && !arm64)

package conpty

// bundled is empty: only the Windows builds for amd64 and arm64 carry a ConPTY.
var bundled []file
