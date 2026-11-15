//go:build !darwin

package workbench

import (
	"context"
	"os/exec"
)

func debugLookupCommand(_ context.Context, name string) (string, error) {
	return exec.LookPath(name)
}
