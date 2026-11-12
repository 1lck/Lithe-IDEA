package workbench

import (
	"context"
	"errors"
	"os/exec"
	"strings"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/buildprocess"
)

// debugLookupCommand asks the selected Apple developer directory only when PATH
// has no such program. xcrun owns tool location and developer-directory selection.
func debugLookupCommand(ctx context.Context, name string) (string, error) {
	executable, err := exec.LookPath(name)
	if err == nil || !errors.Is(err, exec.ErrNotFound) {
		return executable, err
	}
	xcrun, lookupErr := exec.LookPath("xcrun")
	if lookupErr != nil {
		return "", errors.Join(err, lookupErr)
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	var output strings.Builder
	process, startErr := buildprocess.Start(ctx, buildprocess.Spec{Executable: xcrun, Arguments: []string{"--find", name}}, func(stream buildprocess.Stream, text string) {
		if stream == buildprocess.Stdout && output.Len()+len(text) <= 16384 {
			output.WriteString(text)
		}
	})
	if startErr != nil {
		return "", startErr
	}
	if waitErr := process.Wait(); waitErr != nil {
		return "", errors.Join(err, waitErr)
	}
	return exec.LookPath(strings.TrimSpace(output.String()))
}
