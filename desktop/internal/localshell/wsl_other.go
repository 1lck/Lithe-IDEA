//go:build !windows

package localshell

import "context"

// InstalledWSL lists WSL distributions, which only Windows has.
func InstalledWSL(context.Context) []Choice { return nil }
