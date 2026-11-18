package workbench

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const (
	buildProbeFixtureMode  = "LITHE_BUILD_PROBE_FIXTURE_MODE"
	buildProbeFixtureReady = "LITHE_BUILD_PROBE_FIXTURE_READY"
)

// TestBuildToolProbeFixture is invoked by probeBuildTool in a child test binary.
func TestBuildToolProbeFixture(t *testing.T) {
	switch os.Getenv(buildProbeFixtureMode) {
	case "success":
		fmt.Fprintln(os.Stdout, "synthetic tool 1.2.3")
	case "failure":
		fmt.Fprintln(os.Stderr, "invalid runtime root")
		os.Exit(7)
	case "hang":
		if err := os.WriteFile(os.Getenv(buildProbeFixtureReady), []byte("started"), 0o600); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(2)
		}
		fmt.Fprintln(os.Stdout, "version output before hanging")
		<-time.After(30 * time.Second)
	}
}

func runBuildProbeFixture(t *testing.T, ctx context.Context, mode, readyFile string) (string, error) {
	t.Helper()
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	return probeBuildTool(ctx, executable, []string{"-test.run=^TestBuildToolProbeFixture$"}, t.TempDir(), map[string]string{
		buildProbeFixtureMode: mode, buildProbeFixtureReady: readyFile,
	})
}

func TestProbeBuildToolReturnsVersionOnSuccess(t *testing.T) {
	output, err := runBuildProbeFixture(t, context.Background(), "success", "")
	if err != nil || !strings.Contains(output, "synthetic tool 1.2.3") {
		t.Fatalf("success probe = %q, %v", output, err)
	}
}

func TestProbeBuildToolReportsNonzeroExitWithOutput(t *testing.T) {
	output, err := runBuildProbeFixture(t, context.Background(), "failure", "")
	if err == nil || !strings.Contains(err.Error(), "exit status 7") || !strings.Contains(err.Error(), "invalid runtime root") || output != "" {
		t.Fatalf("failed probe = %q, %v; want the exit status and output", output, err)
	}
}

func TestProbeBuildToolTimeoutDoesNotAcceptPartialOutput(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	readyFile := filepath.Join(t.TempDir(), "ready")
	output, err := runBuildProbeFixture(t, ctx, "hang", readyFile)
	if _, statErr := os.Stat(readyFile); statErr != nil {
		t.Fatalf("the probe fixture never started: %v", statErr)
	}
	if output != "" || !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("timed-out probe = %q, %v; want a deadline error, not partial version output", output, err)
	}
}
