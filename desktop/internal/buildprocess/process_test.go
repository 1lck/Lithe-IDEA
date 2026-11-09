package buildprocess

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"sync"
	"testing"
	"time"
)

const helperMode = "LITHE_TEST_BUILD_PROCESS"

// TestBuildProcessHelper is a private subprocess for the tests below. It never
// runs in a product path.
func TestBuildProcessHelper(t *testing.T) {
	mode := os.Getenv(helperMode)
	if mode == "" {
		return
	}
	switch mode {
	case "echo":
		fmt.Fprintln(os.Stdout, "stdout line")
		fmt.Fprintln(os.Stderr, "stderr line")
		os.Exit(0)
	case "sleep":
		fmt.Fprintln(os.Stdout, "started")
		time.Sleep(30 * time.Second)
		os.Exit(0)
	case "orphan-parent":
		child := exec.Command(os.Args[0], "-test.run=^TestBuildProcessHelper$")
		child.Env = append(os.Environ(), helperMode+"=orphan-child")
		child.Stdout = os.Stdout
		child.Stderr = os.Stderr
		if err := child.Start(); err != nil {
			os.Exit(3)
		}
		fmt.Fprintln(os.Stdout, "parent exited")
		os.Exit(0)
	case "orphan-child":
		fmt.Fprintln(os.Stdout, "child holds the pipe")
		time.Sleep(30 * time.Second)
		os.Exit(0)
	case "bulk":
		chunk := strings.Repeat("x", 4096) + "\n"
		for i := 0; i < 128; i++ {
			if _, err := os.Stdout.WriteString(chunk); err != nil {
				os.Exit(4)
			}
		}
		os.Exit(0)
	default:
		os.Exit(2)
	}
}

func processSpec(t *testing.T, mode string) Spec {
	t.Helper()
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	return Spec{
		Executable:       executable,
		Arguments:        []string{"-test.run=^TestBuildProcessHelper$"},
		WorkingDirectory: t.TempDir(),
		Environment:      map[string]string{helperMode: mode},
	}
}

func TestProcessStreamsBothStreamsAndWaits(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	output := make(chan string, 8)
	process, err := Start(ctx, processSpec(t, "echo"), func(_ Stream, text string) {
		output <- text
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := process.Wait(); err != nil {
		t.Fatalf("wait: %v", err)
	}
	close(output)
	var combined strings.Builder
	for text := range output {
		combined.WriteString(text)
	}
	if !strings.Contains(combined.String(), "stdout line") || !strings.Contains(combined.String(), "stderr line") {
		t.Fatalf("output = %q", combined.String())
	}
}

func TestProcessStopEndsASleepingProcess(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	started := make(chan struct{}, 1)
	process, err := Start(ctx, processSpec(t, "sleep"), func(_ Stream, text string) {
		if strings.Contains(text, "started") {
			select {
			case started <- struct{}{}:
			default:
			}
		}
	})
	if err != nil {
		t.Fatal(err)
	}
	select {
	case <-started:
	case <-ctx.Done():
		process.Stop()
		t.Fatal("the helper did not report that it started")
	}
	process.Stop()
	wait := make(chan error, 1)
	go func() { wait <- process.Wait() }()
	select {
	case <-wait:
	case <-ctx.Done():
		t.Fatal("the process did not end after Stop")
	}
}

// A root process that exits normally must not keep Wait blocked on a
// background child that inherited stdout and stderr. The job or process group
// owns the descendants, so root exit ends them and the pipes drain in bounded
// time.
func TestProcessRootExitEndsDetachedChildPipes(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	output := make(chan string, 16)
	process, err := Start(ctx, processSpec(t, "orphan-parent"), func(_ Stream, text string) {
		output <- text
	})
	if err != nil {
		t.Fatal(err)
	}
	wait := make(chan error, 1)
	go func() { wait <- process.Wait() }()
	select {
	case <-wait:
	case <-ctx.Done():
		process.Stop()
		t.Fatal("Wait did not return after the root process exited; a detached child kept the pipes open")
	}
	close(output)
	var combined strings.Builder
	for text := range output {
		combined.WriteString(text)
	}
	if !strings.Contains(combined.String(), "parent exited") {
		t.Fatalf("the root output was lost: %q", combined.String())
	}
}

// A root that writes a large buffer immediately before exit must have every byte
// drained; waiting for root exit must not close the read side early.
func TestProcessDrainsOutputWrittenBeforeRootExit(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	var output strings.Builder
	var outputMu sync.Mutex
	process, err := Start(ctx, processSpec(t, "bulk"), func(_ Stream, text string) {
		outputMu.Lock()
		output.WriteString(text)
		outputMu.Unlock()
	})
	if err != nil {
		t.Fatal(err)
	}
	want := 128 * 4096
	if err := process.Wait(); err != nil {
		t.Fatalf("wait: %v", err)
	}
	outputMu.Lock()
	defer outputMu.Unlock()
	if got := strings.Count(output.String(), "x"); got != want {
		t.Fatalf("drained %d bytes, want %d", got, want)
	}
}

// Stop after Wait must be harmless. The platform layer clears ownership when
// the tree is released, so a late Stop cannot signal a reused process ID.
func TestProcessStopAfterWaitIsHarmless(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	process, err := Start(ctx, processSpec(t, "echo"), nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := process.Wait(); err != nil {
		t.Fatalf("wait: %v", err)
	}
	process.Stop()
	process.Stop()
}

// Stop racing with the root's normal exit must not hang, panic, or double-signal
// the tree. The platform ownership flag serializes the two paths.
func TestProcessStopRacesWithNormalExit(t *testing.T) {
	for i := 0; i < 12; i++ {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		process, err := Start(ctx, processSpec(t, "echo"), nil)
		if err != nil {
			cancel()
			t.Fatal(err)
		}
		done := make(chan error, 1)
		go func() {
			process.Stop()
			done <- process.Wait()
		}()
		select {
		case <-done:
		case <-ctx.Done():
			process.Stop()
			cancel()
			t.Fatalf("iteration %d did not finish after Stop raced with exit", i)
		}
		cancel()
	}
}
