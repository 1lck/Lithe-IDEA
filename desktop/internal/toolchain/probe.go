package toolchain

import (
	"context"
	"errors"
	"os/exec"
	"strings"
	"sync"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/buildprocess"
)

// probeTimeout bounds one version probe. Core's version rule reads bounded
// output; a tool that hangs must not hold the settings page or a run.
const probeTimeout = 5 * time.Second

// probeOutputLimit keeps a talkative tool inside Core's 128 KiB probe budget.
const probeOutputLimit = 128 << 10

var defaultProbe ProbeFunc = func(ctx context.Context, executable string, arguments []string) (string, int, error) {
	return runProbe(ctx, executable, arguments, "")
}

// runProbe starts one host-owned process, passes no shell and returns a bounded
// combined output. The process tree is reclaimed by buildprocess on every path.
func runProbe(ctx context.Context, executable string, arguments []string, workingDirectory string) (string, int, error) {
	if ctx.Err() != nil {
		return "", -1, ctx.Err()
	}
	probeCtx, cancel := context.WithTimeout(ctx, probeTimeout)
	defer cancel()
	var output strings.Builder
	var mu sync.Mutex
	process, err := buildprocess.Start(probeCtx, buildprocess.Spec{
		Executable:       executable,
		Arguments:        arguments,
		WorkingDirectory: workingDirectory,
	}, func(_ buildprocess.Stream, text string) {
		mu.Lock()
		if output.Len() < probeOutputLimit {
			remaining := probeOutputLimit - output.Len()
			if len(text) > remaining {
				text = text[:remaining]
			}
			output.WriteString(text)
		}
		mu.Unlock()
	})
	if err != nil {
		return "", -1, err
	}
	if probeCtx.Err() != nil {
		process.Stop()
	}
	waitErr := process.Wait()
	mu.Lock()
	result := output.String()
	mu.Unlock()
	code := 0
	if waitErr != nil {
		var exit *exec.ExitError
		if errors.As(waitErr, &exit) {
			code = exit.ExitCode()
		} else if probeCtx.Err() != nil {
			return "", -1, probeCtx.Err()
		} else {
			return "", -1, waitErr
		}
	}
	return result, code, nil
}
